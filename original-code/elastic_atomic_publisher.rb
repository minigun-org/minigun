# frozen_string_literal: true

module Vesper
module Publisher
  class ElasticAtomicPublisher < Vesper::Publisher::PublisherBase
    # TODO: Add TC models
    # Vesper::Table::Shop
    # Vesper::Table::MenuItem
    MODELS = %w[ Vesper::Table::Franchise
                 Vesper::Table::Customer
                 Vesper::Table::CustomerMembership
                 Vesper::Table::Reservation
                 Vesper::Table::Payment
                 Vesper::Table::PosJournal
                 Vesper::Table::Voucher ].freeze

    MODEL_INCLUDES = {
      'Vesper::Table::Reservation' => %i[customers],
      'Vesper::Table::CustomerMembership' => %i[customers],
      'Vesper::Table::Payment' => [reservation: %i[customers]],
      'Vesper::Table::PosJournal' => [reservation: %i[customers]],
      'Vesper::Table::Voucher' => %i[voucher_bundle voucher_product_snapshot reservation]
    }.deep_freeze

    private

    def consume_batch(model, object_ids)
      case model.to_s
      when 'Vesper::Table::Customer'
        ::Vesper::Elastic::Upserter::CustomersMultiUpserter.new(object_ids).bulk_upsert
      when 'Vesper::Table::CustomerMembership'
        ::Vesper::Elastic::Upserter::MembershipsMultiUpserter.new(object_ids).bulk_upsert
      when 'Vesper::Table::Reservation'
        ::Vesper::Elastic::Upserter::ReservationsMultiUpserter.new(object_ids).bulk_upsert
      when 'Vesper::Table::Payment'
        ::Vesper::Elastic::Upserter::PaymentsMultiUpserter.new(object_ids).bulk_upsert
      when 'Vesper::Table::PosJournal'
        ::Vesper::Elastic::Upserter::PosJournalsMultiUpserter.new(object_ids).bulk_upsert
      when 'Vesper::Table::Voucher'
        ::Vesper::Elastic::Upserter::VouchersMultiUpserter.new(object_ids).bulk_upsert
      else
        return super
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

    def default_models
      MODELS
    end
  end
end
end
