# frozen_string_literal: true

module Vesper
module Publisher
  class JourneyEventsPublisher < Vesper::Publisher::PublisherBase
    class MissingJourneyEventsError < StandardError; end

    MODELS = ['Vesper::Table::Reservation'].freeze
    MISSING_EVENTS_THRESHOLD = 0.05 # 5%
    MIN_EVENTS_FOR_NOTIFICATION = 100

    private

    # overriden to use created_at instead of updated_at and add online scope
    def produce_model(model, range)
      count = 0
      model.unscoped.online.where(created_at: range).pluck_each(:_id) do |id|
        @object_id_queue << [model, id.to_s.freeze].freeze
        @producer_mutex.synchronize { @produced_count += 1 }
        count += 1
      end
      count
    end

    def consume_object(object)
      success_event = Vesper::Table::JourneyEvent.where(
        journey_type: :reserve,
        event_type: :reserve_success,
        reservation_id: object._id
      ).last

      unless success_event
        track_missing_event(object._id)
        return
      end

      previous_success_event = Vesper::Table::JourneyEvent
                               .where(
                                 journey_type: :reserve,
                                 event_type: :reserve_success,
                                 session_ref: success_event.session_ref
                               )
                               .lt(created_at: success_event.created_at)
                               .last

      query = Vesper::Table::JourneyEvent
              .lt(created_at: success_event.created_at)
              .in(cart_id: [success_event.cart_id, nil])
              .where(
                journey_type: :reserve,
                session_ref: success_event.session_ref,
                reservation_id: nil,
                shop_id: object.shop_id
              )

      if previous_success_event
        query = query.gt(created_at: previous_success_event.created_at)
      end

      query.update_all(reservation_id: object._id)
    end

    def track_missing_event(reservation_id)
      @missing_events_count ||= 0
      @total_events_count ||= 0
      @reservations_without_success ||= []

      @missing_events_count += 1
      @total_events_count += 1
      @reservations_without_success << reservation_id

      return unless @total_events_count >= MIN_EVENTS_FOR_NOTIFICATION

      missing_ratio = @missing_events_count.to_f / @total_events_count
      if missing_ratio > MISSING_EVENTS_THRESHOLD
        error = MissingJourneyEventsError.new("#{@missing_events_count}/#{@total_events_count} reservations missing success events")

        Bugsnag.notify(error, severity: "warning") do |report|
          report.add_metadata(:journey_events, {
            missing_count: @missing_events_count,
            total_count: @total_events_count,
            missing_ratio: missing_ratio,
            reservation_ids: @reservations_without_success
          })
        end
      end

      # Reset counters
      @missing_events_count = 0
      @total_events_count = 0
      @reservations_without_success = []
    end

    def default_models
      MODELS
    end
  end
end
end
