# frozen_string_literal: true

module Vesper
module Publisher
  # Publisher to trigger auto-tagging rules that need to run on a schedule.
  # Currently handles Birthday and Anniversary rules that need to be checked daily.
  class AutoTagScheduledPublisher < Vesper::Publisher::PublisherBase

    # List of rule types that need to be checked on a schedule
    SCHEDULED_RULE_TYPES = %i[
      HistoryLastVisitDateRule
      PaymentsTopSpenderRule
      ProfileBirthdayDaysFromNowRule
      ProfileAnniversaryDaysFromNowRule
      PosTopSpenderRule
    ].freeze

    def initialize(**options)
      @limit_once_per_day = !!options.delete(:limit_once_per_day)
      super
    end

    def perform
      return if should_skip_run?
      super
    end

    private

    def bootstrap!
      instrumenter
      super
    end

    def instrumenter
      @instrumenter ||= AutoTagTaskInstrumenter.new(self)
    end

    def should_skip_run?
      return false unless @limit_once_per_day

      last_run = Vesper::Table::AutoTagEvent.where(event_type: :scheduled_job_run)
                                            .order(created_at: :desc)
                                            .first
      return false if last_run.nil?

      last_run.created_at.to_date == Time.current.to_date
    end

    def after_job_finished!
      Vesper::Table::AutoTagEvent.create!(event_type: :scheduled_job_run, created_at: time_range.first)
      instrumenter.save!
    end

    def default_models
      ['Vesper::Table::AutoTagRule']
    end

    # Core logic executed for each rule found by the producer.
    def consume_object(object)
      rule_type = object.rule_type.to_sym
      case rule_type
      when :HistoryLastVisitDateRule
        process_last_visit_date_rule(object)
      when :PaymentsTopSpenderRule, :PosTopSpenderRule
        process_top_spender_rule(object)
      when :ProfileBirthdayDaysFromNowRule
        process_birthday_rule(object)
      when :ProfileAnniversaryDaysFromNowRule
        process_anniversary_rule(object)
      when :LogicalAndRule
        object.child_rules.each do |child_rule|
          consume_object(child_rule) if SCHEDULED_RULE_TYPES.include?(child_rule.rule_type.to_sym)
        end
      else
        raise ArgumentError.new("Unsupported rule type: #{rule_type}")
      end
    end

    def process_last_visit_date_rule(rule)
      # "Have not visited in the last N days" rule checks have to be scheduled since they are triggered by the date rather than the event
      return unless rule.comparator == :not_within_days

      customers = Vesper::Table::Customer.where({
        reservations_fields: { '$not' => { '$elemMatch' => { 'start_at' => { '$gte' => rule.value.days.ago } } } },
        franchise_id: rule.franchise_id,
        deleted_at: nil
       }).all.to_a
      process_customers_for_rule(customers, rule)
    end

    def process_birthday_rule(rule)
      # Find customers with birthdays in the next N days
      customers = find_customers_with_upcoming_event(:birthday, rule.value, rule.franchise_id)
      process_customers_for_rule(customers, rule)
    end

    def process_anniversary_rule(rule)
      # Find customers with anniversaries in the next N days
      customers = find_customers_with_upcoming_event(:anniversary, rule.value, rule.franchise_id)
      process_customers_for_rule(customers, rule)
    end

    def process_top_spender_rule(rule)
      # Use the rule's cache to get all matching customers at once
      rule.rule_builder_class.use_cache_for_rule(rule) do |matching_customer_ids|
        # Find all customers that either match the rule or currently have the tag
        affected_customers = Vesper::Table::Customer.where({
          '$or' => [
            { _id: { '$in' => matching_customer_ids } },
            { customer_tags: { '$elemMatch': { auto_tag_rule_id: rule._id } } }
          ],
          'franchise_id' => rule.franchise_id,
          'deleted_at' => nil
        }).to_a

        # Process all affected customers (will both add and remove the tag as needed)
        process_customers_for_rule(affected_customers, rule)
      end
    end

    def find_customers_with_upcoming_event(event_type, days_ahead, franchise_id)
      current_day = Date.current.yday
      end_day = (Date.current + days_ahead.days).yday

      # Build the base aggregation pipeline
      pipeline = [
        { '$match' => {
          'evts.tag' => event_type.to_s,
          'franchise_id' => franchise_id,
          'deleted_at' => nil
        } },
        { '$unwind' => '$evts' },
        { '$match' => { 'evts.tag' => event_type.to_s } },
        { '$addFields' => {
          'event_day' => {
            '$dayOfYear' => '$evts.dt'
          }
        } }
      ]

      # Add the appropriate day range match based on whether we're crossing year boundary
      pipeline << if end_day < current_day
                    # Crossing year boundary - need to match days from current to end of year AND start of year to end_day
                    {
                      '$match' => {
                        '$or' => [
                          { 'event_day' => { '$gte' => current_day } },
                          { 'event_day' => { '$lte' => end_day } }
                        ]
                      }
                    }
                  else
                    # Simple case - all within current year
                    {
                      '$match' => {
                        'event_day' => { '$gte' => current_day, '$lte' => end_day }
                      }
                    }
                  end

      # Group back by customer
      pipeline << {
        '$group' => {
          '_id' => '$_id',
          'customer' => { '$first' => '$$ROOT' }
        }
      }

      # Execute the aggregation to get matching customer IDs
      customer_ids = Vesper::Table::Customer.collection.aggregate(pipeline).pluck('_id')

      # Fetch all matching customers in a single query
      Vesper::Table::Customer.where(_id: { '$in' => customer_ids }).to_a
    end

    def process_customers_for_rule(customers, rule)
      rule = rule.parent_auto_tag_rule if rule.is_a?(Vesper::Table::AutoTagRuleChild)
      customers.each do |customer|
        # Run the rule for each customer
        instrumenter.measure(rule, customer) do
          rule.run_for_customer!(customer)
        end
      end
    end

    # Override produce_model to only find rules of the scheduled types
    def produce_model(model, _range)
      count = 0

      model.where(
        '$or' => [
          { rule_type: { '$in' => SCHEDULED_RULE_TYPES } },
          { 'child_rules.rule_type' => { '$in' => SCHEDULED_RULE_TYPES } }
        ],
        enabled: true
      ).pluck_each(:_id) do |id|
        @object_id_queue << [model, id.to_s.freeze].freeze
        @producer_mutex.synchronize { @produced_count += 1 }
        count += 1
      end
      count
    end
  end
end
end
