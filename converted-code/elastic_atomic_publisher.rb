# frozen_string_literal: true

require_relative 'publisher_base_simple'

# Publisher for upserting Vesper models to Elasticsearch
# This is a converted version of the original ElasticAtomicPublisher
# using the simplified PublisherBaseSimple class
class ElasticAtomicPublisher < PublisherBaseSimple
  MODELS = %w[
    Vesper::Table::Franchise
    Vesper::Table::Customer
    Vesper::Table::CustomerMembership
    Vesper::Table::Reservation
    Vesper::Table::Payment
    Vesper::Table::PosJournal
    Vesper::Table::Voucher
  ].freeze

  MODEL_INCLUDES = {
    'Vesper::Table::Reservation' => %i[customers],
    'Vesper::Table::CustomerMembership' => %i[customers],
    'Vesper::Table::Payment' => [reservation: %i[customers]],
    'Vesper::Table::PosJournal' => [reservation: %i[customers]],
    'Vesper::Table::Voucher' => %i[voucher_bundle voucher_product_snapshot reservation]
  }.freeze

  private

  def default_models
    MODELS
  end

  def consumer_scope(model, object_ids)
    includes = MODEL_INCLUDES[model.to_s]
    scope = model.unscoped.any_in(_id: object_ids)
    scope = scope.includes(includes) if includes
    scope
  end

  def consume_batch(model, object_ids)
    # Use multi-upserters for better performance
    case model.to_s
    when 'Vesper::Table::Customer'
      Vesper::Elastic::Upserter::CustomersMultiUpserter.new(object_ids).bulk_upsert
    when 'Vesper::Table::CustomerMembership'
      Vesper::Elastic::Upserter::MembershipsMultiUpserter.new(object_ids).bulk_upsert
    when 'Vesper::Table::Reservation'
      Vesper::Elastic::Upserter::ReservationsMultiUpserter.new(object_ids).bulk_upsert
    when 'Vesper::Table::Payment'
      Vesper::Elastic::Upserter::PaymentsMultiUpserter.new(object_ids).bulk_upsert
    when 'Vesper::Table::PosJournal'
      Vesper::Elastic::Upserter::PosJournalsMultiUpserter.new(object_ids).bulk_upsert
    when 'Vesper::Table::Voucher'
      Vesper::Elastic::Upserter::VouchersMultiUpserter.new(object_ids).bulk_upsert
    else
      # Fall back to individual processing
      super
    end

    object_ids.size
  end

  def consume_object(object)
    if object.try(:archived?)
      object.elastic_destroy!
    else
      object.elastic_upsert!
    end
  end
end

# Usage:
# publisher = ElasticAtomicPublisher.new(
#   start_time: 1.hour.ago,
#   end_time: Time.current,
#   max_processes: 4,
#   max_threads: 10
# )
# publisher.perform

