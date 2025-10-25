# frozen_string_literal: true

require_relative 'publisher_base'

# Converted from original ElasticAtomicPublisher to use Minigun
# Demonstrates inheritance pattern with PublisherBase
class ElasticAtomicPublisher < PublisherBase
  MODELS = %w[
    Franchise
    Customer
    CustomerMembership
    Reservation
    Payment
    PosJournal
    Voucher
  ].freeze

  # Override consume_object to add Elastic-specific logic
  def consume_object(model, id)
    # Stub: In real code, this would fetch the object and call elastic methods
    object = fetch_object(model, id)

    if object[:archived]
      elastic_destroy(model, id)
    else
      elastic_upsert(model, id, object)
    end
  end

  def default_models
    MODELS
  end

  private

  def fetch_object(model, id)
    # Stub: Simulate fetching object from database
    # In real code: model.unscoped.find(id)
    {
      id: id,
      model: model,
      archived: rand > 0.9, # 10% archived
      data: { name: "#{model} #{id[0..7]}" }
    }
  end

  def elastic_destroy(model, id)
    # Stub: In real code, this would call Elasticsearch delete API
    puts "[Elastic] Destroying #{model}##{id[0..15]}..."
  end

  def elastic_upsert(model, id, object)
    # Stub: In real code, this would call Elasticsearch index/update API
    puts "[Elastic] Upserting #{model}##{id[0..15]}: #{object[:data]}"
  end
end

# Example usage
if __FILE__ == $0
  puts "=== ElasticAtomicPublisher Example ===\n\n"

  publisher = ElasticAtomicPublisher.new(
    models: ['Customer', 'Reservation'],
    start_time: Time.now - 86400, # 1 day in seconds
    end_time: Time.now,
    max_processes: 2,
    max_threads: 5
  )

  publisher.run

  puts "\n=== Final Stats ===\n"
  puts "Produced: #{publisher.produced_count} IDs"
  puts "Accumulated: #{publisher.accumulated_count} items"
  puts "Consumed: #{publisher.consumed_count} items"
end

