# frozen_string_literal: true

module Vesper
module Publisher
  class AvailabilityCachePublisher < Vesper::Publisher::PublisherBase
    MODELS = %w[ Vesper::Table::Shop
                 Vesper::Table::Pace
                 Vesper::Table::Sheet
                 Vesper::Table::SheetOverride
                 Vesper::Table::HolidayOverride
                 Vesper::Table::Table
                 Vesper::Table::TableCombo
                 Vesper::Table::Stoppage
                 Vesper::Table::Blockage
                 Vesper::Table::RepeatBlockage
                 Vesper::Table::Reservation ].freeze

    MODEL_INCLUDES = {
      'Vesper::Table::Shop' => %i[sheets paces sections floor_plans tables table_combos blockages menu_items]
    }.deep_freeze

    DAYS_PER_STEP = 5
    FULL_REFRESH = :full

    def perform
      return unless Settings.env.tc_mongo_cache_enabled

      @from = Date.current
      @till = @from + VesperCache::AvailabilityCache::CACHED_DATE_SPAN
      @shops_to_refresh = {}
      @shops_to_refresh_mutex = Mutex.new
      @shops_queue = []

      in_time_zone_and_locale do
        bootstrap!
        job_start_at
        report_job_started
        before_job_start!
        producer_thread = start_producer_thread
        producer_thread.join
        # starting accumulator thread only after producer thread is finished to get all data at once
        accumulator_thread = start_accumulator_thread
        accumulator_thread.join
        wait_all_consumer_processes
        report_job_finished
        after_job_finished!
      end
    end

    private

    def produce_model(model, range)
      count = 0
      model_name = model.to_s

      scope = model.unscoped.where(availability_updated_at: range)

      if model_name == 'Vesper::Table::Blockage'
        scope = model.unscoped.where(
          "$or" => [
            { blockage_type: { "$in" => %i[hard soft ghost] }, availability_updated_at: range },
            { blockage_type: :ghost, expires_at: range }
          ]
        )
      end

      case model_name
      when 'Vesper::Table::Reservation', 'Vesper::Table::Blockage'
        scope.pluck_each(:shop_id, :start_at) do |shop_id, start_at|
          count += 1
          @shops_to_refresh_mutex.synchronize do
            next if @shops_to_refresh[shop_id] == FULL_REFRESH
            @shops_to_refresh[shop_id] ||= Set.new
            @shops_to_refresh[shop_id] << VesperMatrixPlus::DatetimeExt.extract_date(start_at)
          end
        end
      when 'Vesper::Table::Stoppage'
        scope.pluck_each(:shop_id, :date) do |shop_id, date|
          count += 1
          @shops_to_refresh_mutex.synchronize do
            next if @shops_to_refresh[shop_id] == FULL_REFRESH
            @shops_to_refresh[shop_id] ||= Set.new
            @shops_to_refresh[shop_id] << date
          end
        end
      when 'Vesper::Table::RepeatBlockage'
        scope.pluck_each(:shop_id, :start_date, :end_date) do |shop_id, start_date, end_date|
          start_date = [start_date, Date.current].max
          end_date = [end_date, max_cache_date].compact.min
          range = (start_date..end_date)
          @shops_to_refresh_mutex.synchronize do
            next if @shops_to_refresh[shop_id] == FULL_REFRESH
            if range.count > VesperCache::AvailabilityCache::CACHED_DATE_SPAN - DAYS_PER_STEP
              @shops_to_refresh[shop_id] = FULL_REFRESH
              next
            end

            range.each do |date|
              @shops_to_refresh[shop_id] ||= Set.new
              @shops_to_refresh[shop_id] << date
            end
          end
        end
      else
        target_attribute = model_name == 'Vesper::Table::Shop' ? :_id : :shop_id
        scope.pluck_each(target_attribute) do |id|
          count += 1
          @shops_to_refresh_mutex.synchronize do
            @shops_to_refresh[id] = FULL_REFRESH
          end
        end
      end
      count
    end

    def max_cache_date
      Date.current + VesperCache::AvailabilityCache::CACHED_DATE_SPAN
    end

    def after_producer_finished!
      count = 0
      days = 0
      @shops_to_refresh.each do |shop_id, dates|
        if dates == FULL_REFRESH
          count += produce_shop_full_refresh(shop_id)
          days += VesperCache::AvailabilityCache::CACHED_DATE_SPAN
        else
          dates = dates.sort
          compacted_dates = []
          dates.each do |date|
            if compacted_dates.count == DAYS_PER_STEP || (compacted_dates.present? && compacted_dates.last != date - 1)
              days += compacted_dates.count
              count += produce_shop_refresh(shop_id, compacted_dates.first, compacted_dates.count - 1)
              compacted_dates.clear
            end

            compacted_dates << date
          end

          days += compacted_dates.count
          count += produce_shop_refresh(shop_id, compacted_dates.first, compacted_dates.count - 1) if compacted_dates.present?
        end
      end
      @shops_to_refresh = nil
      Rails.logger.info { "[Producer]: Produced #{count} compacted refresh jobs, for #{days} days." }
    end

    def produce_shop_refresh(shop_id, date, duration_in_days)
      @shops_queue << [shop_id.to_s.freeze, date, duration_in_days].freeze
      @producer_mutex.synchronize { @produced_count += 1 }
      1
    end

    def produce_shop_full_refresh(shop_id)
      count = 0
      (@from..@till).step(DAYS_PER_STEP).each do |date|
        @shops_queue << [shop_id.to_s.freeze, date, DAYS_PER_STEP].freeze
        count += 1
        @producer_mutex.synchronize { @produced_count += 1 }
      end
      count
    end

    def start_accumulator_thread
      @consumer_pids = []
      Thread.new do
        Rails.logger.info { "[Accumulator] Started accumulator thread." }

        items_per_fork = @shops_queue.size / max_processes

        GC.start
        (max_processes - 1).times do
          next if @shops_queue.empty?
          items = @shops_queue.pop(items_per_fork)
          fork_consumer({ Vesper::Table::Shop => items })
          @accumulated_count += items.count
        end

        if @shops_queue.present?
          consume_object_ids({ Vesper::Table::Shop => @shops_queue })
          @accumulated_count += @shops_queue.count
        end
      end
    end

    def consume_batch(model, object_ids_and_params)
      count = 0
      object_ids = object_ids_and_params.map(&:first).uniq
      objects = consumer_scope(model, object_ids).to_a.index_by {|m| m.id.to_s }

      object_ids_and_params.each do |object_id, start_date, duration_in_days|
        raise "No object found for #{model} #{object_id}" unless objects[object_id]
        consume_object(objects[object_id], start_date, duration_in_days)
        count += 1
      rescue StandardError => e
        Bugsnag.notify(e) {|r| r.add_metadata('publisher', model: model.to_s, object_id: object_id) }
      end
      count
    end

    def consume_object(object, start_date, duration_in_days)
      Time.use_zone(object.time_zone) do
        VesperCache::AvailabilityCache.refresh_for_shop!(object,
                                                         start_date: start_date,
                                                         duration_in_days: duration_in_days,
                                                         service: :mongo)
      end
    end

    def default_models
      MODELS
    end
  end
end
end
