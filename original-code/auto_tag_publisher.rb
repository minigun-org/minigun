# frozen_string_literal: true

module Vesper
module Publisher
  # Publisher to trigger auto-tagging rules based on model updates.
  # Scans for updated records within the specified time range.
  # For each update, it checks if the associated Franchise has relevant
  # AutoTagRules (History*) and applies them to the Customer if found.
  class AutoTagPublisher < Vesper::Publisher::PublisherBase

    # As more AutoTagRule types are added, this list may need to be updated.
    MODELS = %w[
      Vesper::Table::AutoTagRule
      Vesper::Table::Customer
      Vesper::Table::CustomerUser
      Vesper::Table::Payment
      Vesper::Table::PosJournal
      Vesper::Table::Reservation
      Vesper::Table::SurveyResponse
    ].freeze

    # Eager load associations needed in consume_object to avoid N+1 queries.
    MODEL_INCLUDES = {
      'Vesper::Table::CustomerUser' => %i[customers],
      'Vesper::Table::Payment' => [{ reservation: %i[customers] }],
      'Vesper::Table::PosJournal' => [:franchise, { reservation: %i[customers] }],
      'Vesper::Table::Reservation' => [{ customers: %i[franchise] }],
      'Vesper::Table::SurveyResponse' => %i[franchise customer]
    }.freeze

    # Map each model to the types of AutoTagRules that should respond to
    # the model's updates.
    OBSERVED_MODEL_TYPES = {
      Vesper::Table::Customer => %i[
        ProfileLocaleRule
      ].freeze,
      Vesper::Table::CustomerUser => %i[
        ProfileLocaleRule
      ].freeze,
      Vesper::Table::Payment => %i[
        PaymentsAverageSpendPerGuestRule
        PaymentsAverageSpendRule
        PaymentsLastSpendRule
        PaymentsLifetimeSpendRule
      ].freeze,
      Vesper::Table::PosJournal => %i[
        PosAverageSpendPerGuestRule
        PosAverageSpendRule
        PosLastSpendRule
        PosLifetimeSpendRule
      ].freeze,
      Vesper::Table::Reservation => %i[
        HistoryCancellationCountRule
        HistoryLastVisitDateRule
        HistoryNoShowCountRule
        HistoryPartySizeRule
        HistoryReservationMediaRule
        HistoryReservationSourceRule
        HistoryVisitCountRule
        HistoryVisitedVenuesRule
      ].freeze,
      Vesper::Table::SurveyResponse => %i[
        SurveyOverallRatingRule
        SurveyFoodRatingRule
        SurveyServiceRatingRule
        SurveyAtmosphereRatingRule
        SurveyValueRatingRule
        SurveyCleanlinessRatingRule
        SurveyFeedbackRatingRule
        SurveyOtherRatingRule
        SurveyScoreRule
        SurveyCountRule
      ].freeze
    }.freeze

    def initialize(**options)
      @franchises_with_rules = Vesper::Table::AutoTagRule.unscoped.all.pluck(:franchise_id).uniq.to_set
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

    def time_range
      @time_range ||= in_time_zone_and_locale do
        start_time = Vesper::Table::AutoTagEvent.where(event_type: :job_run).order(created_at: :desc).first&.created_at
        start_time ||= @start_time&.beginning_of_day if @start_time.is_a?(Date)
        start_time ||= @start_time&.in_time_zone
        raise ArgumentError.new('Must specify :start_time') unless start_time

        end_time = Time.current.in_time_zone

        start_time..end_time
      end
    end

    def after_job_finished!
      Vesper::Table::AutoTagEvent.create!(event_type: :job_run, created_at: time_range.end)
      instrumenter.save!
    end

    def default_models
      MODELS
    end

    # Core logic executed for each updated object found by the producer.
    def consume_object(object)
      case object
      when Vesper::Table::AutoTagRule
        process_auto_tag_rule(object)
      when Vesper::Table::Customer
        process_customer(object)
      when Vesper::Table::CustomerUser
        process_customer_user(object)
      when Vesper::Table::Payment
        process_payment(object)
      when Vesper::Table::PosJournal
        process_pos_journal(object)
      when Vesper::Table::Reservation
        process_reservation(object)
      when Vesper::Table::SurveyResponse
        process_survey_response(object)
      else
        raise ArgumentError.new("Unsupported model: #{object.class}")
      end
    end

    def process_auto_tag_rule(auto_tag_rule)
      # If an auto-tag rule is updated, we need to re-evaluate all tags currently
      # associated with it to make sure they're still valid. Otherwise we run the
      # risk of tags being "stuck" on a customer if nothing else ever triggers
      # an update.
      auto_tag_rule.customers.each do |customer|
        instrumenter.measure(auto_tag_rule, customer) do
          auto_tag_rule.run_for_customer!(customer)
        end
      end
    end

    def process_customer_user(customer_user)
      customer_user.customers.each do |customer|
        execute_rule!(customer.franchise, customer, customer)
      end
    end

    def process_payment(payment)
      payment.reservation&.customers&.each do |customer|
        execute_rule!(customer.franchise, payment, customer)
      end
    end

    def process_pos_journal(pos_journal)
      pos_journal.reservation&.customers&.each do |customer|
        execute_rule!(pos_journal.franchise, pos_journal, customer)
      end
    end

    def process_reservation(reservation)
      reservation.customers.each do |customer|
        execute_rule!(customer.franchise, reservation, customer)
      end
    end

    def process_survey_response(survey_response)
      return unless survey_response.customer
      execute_rule!(survey_response.franchise, survey_response, survey_response.customer)
    end

    def process_customer(customer)
      # Check for rules driven by Customer updates.
      execute_rule!(customer.franchise, customer, customer)

      # Check for CustomerTag expirations.
      customer.customer_tags.select(&:expired?).each do |tag|
        if tag.auto_tag_rule
          # Rerun the rule to verify the tag is still expired.
          instrumenter.measure(tag.auto_tag_rule, customer.reload) do
            tag.auto_tag_rule.run_for_customer!(customer.reload)
          end
        else
          # If there is no identifiable rule (e.g. the rule was deleted),
          # just remove the expired tag.
          tag.destroy_with_tracking
        end
      end
    end

    # Helper method to fetch relevant AutoTagRules for a given franchise and model class.
    def rules_for(franchise, model)
      return [] unless @franchises_with_rules.include?(franchise._id)

      observed_types = OBSERVED_MODEL_TYPES[model.class]

      Vesper::Table::AutoTagRule.where(
        franchise_id: franchise._id,
        '$or' => [
          { rule_type: { '$in' => observed_types } },
          { 'child_rules.rule_type' => { '$in' => observed_types } }
        ]
      )
    end

    # Execute all relevant rules for a franchise and target, with performance tracking.
    def execute_rule!(franchise, target, customer)
      rules_for(franchise, target).each do |rule|
        instrumenter.measure(rule, customer) do
          rule.run_for_customer!(customer)
        end
      end
    end

    # Override produce_model to include both updated models and expiring CustomerTags
    def produce_model(klass, range)
      case klass.to_s
      when 'Vesper::Table::Reservation'
        # Reservations should be processed if one of the following conditions is met:
        # - The reservation was updated within the default range (typically last 30 minutes)
        # - The reservation's start_at is within the default range shifted back
        #   by PAST_CUTOFF (i.e., if the default range is the last 30 minutes, then
        #   this includes reservations that started 3.5hr to 3hr ago).
        # The first condition allows for past reservations to be updated quickly.
        # The second condition keeps behavior consistent with other application logic
        # requiring PAST_CUTOFF hours to pass for a reservation to be considered "past".
        count = 0
        completed_reservation_range = (range.begin - Vesper::Table::Reservation::PAST_CUTOFF)..(range.end - Vesper::Table::Reservation::PAST_CUTOFF)
        Vesper::Table::Reservation.any_of(
          [
            { updated_at: range },
            { start_at: completed_reservation_range }
          ]
        ).pluck_each(:_id) do |id|
          @object_id_queue << [klass, id.to_s.freeze].freeze
          @producer_mutex.synchronize { @produced_count += 1 }
          count += 1
        end

        count
      when 'Vesper::Table::Customer'
        count = 0
        # For Customer, we need to produce both updated models and models with expired CustomerTags.
        # Use an aggregation pipeline to skip franchises that have no auto tag rules.
        pipeline = [
          {
            '$lookup' => {
              'from' => 'auto_tag_rules',
              'localField' => 'franchise_id',
              'foreignField' => 'franchise_id',
              'as' => 'franchise_rules'
            }
          },
          {
            '$match' => {
              'franchise_rules' => { '$ne' => [] },
              '$or' => [
                { 'u_at' => { '$gte' => range.begin, '$lte' => range.end } },
                { 'ctgs' => { '$elemMatch' => { 'expires_at' => { '$lte' => range.end } } } }
              ]
            }
          },
          {
            '$project' => { '_id' => 1 }
          }
        ]

        Vesper::Table::Customer.collection.aggregate(pipeline).each do |doc|
          @object_id_queue << [klass, doc['_id'].to_s.freeze].freeze
          @producer_mutex.synchronize { @produced_count += 1 }
          count += 1
        end

        count
      else
        super
      end
    end
  end
end
end
