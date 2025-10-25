# frozen_string_literal: true

module Vesper
module Publisher
  class ElasticBulkPublisher < ElasticAtomicPublisher
    ACCUMULATOR_DUPES_MAX_SIZE = 1_000_000

    private

    # Vouchers are handled by super as they can be without a customer_id
    def produce_model(model, range)
      count = 0
      case model.to_s
      when 'Vesper::Table::Reservation', 'Vesper::Table::CustomerMembership'
        model_base_scope(model).where(updated_at: range).pluck_each(:customer_ids) do |ids|
          count += produce_customer_ids(ids)
        end
      when 'Vesper::Table::Payment', 'Vesper::Table::PosJournal'
        reservation_ids = model_base_scope(model).where(updated_at: range).distinct(:reservation_id).compact_blank!
        reservation_ids.each_slice(200) do |batch|
          Vesper::Table::Reservation.unscoped.any_in(_id: batch).pluck_each(:customer_ids) do |ids|
            count += produce_customer_ids(ids)
          end
        end
      else
        return super
      end
      count
    end

    def produce_customer_ids(customer_ids)
      count = 0
      customer_ids.uniq.compact_blank!.each do |id|
        @object_id_queue << [Vesper::Table::Customer, id.to_s.freeze].freeze
        @producer_mutex.synchronize { @produced_count += 1 }
        count += 1
      end
      count
    end

    def consume_batch(model, object_ids)
      return super unless model == Vesper::Table::Customer

      # Returns count of processed objects
      ::Vesper::Elastic::Upserter::CustomersBulkUpserter.new(object_ids).bulk_upsert
      object_ids.size
    end

    def accumulator_dupes
      @accumulator_dupes ||= Set.new
    end

    def fork_consumer(object_map)
      if (ids = object_map[Vesper::Table::Customer]).present?
        ids.delete_if {|id| accumulator_dupes.include?(id) }
        accumulator_dupes.merge(ids) if accumulator_dupes.size < ACCUMULATOR_DUPES_MAX_SIZE
      end

      super
    end

    def after_consumer_fork!
      super
      accumulator_dupes.clear
    end
  end
end
end
