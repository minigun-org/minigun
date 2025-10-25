# frozen_string_literal: true

module Vesper
module Publisher
  # Tracks performance statistics for auto-tagging publishers,
  # including timing, customer processing, and tag operations.
  class AutoTagTaskInstrumenter
    def initialize(instance = nil, task_start_at: nil)
      @klass_name = instance&.class&.name&.demodulize
      @task_start_at = task_start_at || instance&.try(:job_start_at) || Time.current
      @stats = {}
      @mutex = Mutex.new
    end

    def measure(rule, customer)
      rule_type = rule.rule_type.to_s
      franchise_id = rule.franchise_id

      @mutex.synchronize do
        key = "#{franchise_id}_#{rule_type}"
        @stats[key] ||= {
          franchise_id: franchise_id,
          rule_type: rule_type,
          execution_count: 0,
          total_execution_time_ms: 0,
          customers_processed: 0,
          customers_matched: 0,
          tags_created: 0,
          tags_updated: 0,
          tags_deleted: 0
        }
      end

      start_time = Time.current
      tags_before = customer.customer_tags.count

      result = yield

      execution_time_ms = (Time.current - start_time).in_milliseconds.round

      tags_after = customer.customer_tags.count
      net_change = tags_after - tags_before
      tags_created = [net_change, 0].max
      tags_deleted = [-net_change, 0].max
      # If we have a result (tag) but no net change in tags, it was an update
      tags_updated = result.is_a?(Vesper::Table::CustomerTag) && net_change == 0 ? 1 : 0
      matched = result.present?

      @mutex.synchronize do
        key = "#{franchise_id}_#{rule_type}"
        stat = @stats[key]
        stat[:execution_count] += 1
        stat[:total_execution_time_ms] += execution_time_ms
        stat[:customers_processed] += 1
        stat[:customers_matched] += 1 if matched
        stat[:tags_created] += tags_created
        stat[:tags_updated] += tags_updated
        stat[:tags_deleted] += tags_deleted
      end

      result
    end

    def save!
      return if @stats.empty?

      @stats.each_value do |stat|
        Vesper::Table::AutoTagTaskStat.create!(
          franchise_id: stat[:franchise_id],
          rule_type: stat[:rule_type],
          task_start_at: @task_start_at,
          execution_count: stat[:execution_count],
          total_execution_time_ms: stat[:total_execution_time_ms],
          customers_processed: stat[:customers_processed],
          customers_matched: stat[:customers_matched],
          tags_created: stat[:tags_created],
          tags_updated: stat[:tags_updated],
          tags_deleted: stat[:tags_deleted]
        )
      end

      Rails.logger.info { "#{log_tag}Stats saved for #{@stats.size} rule types" }
    rescue StandardError => e
      Rails.logger.error { "#{log_tag}Failed to save stats: #{e.message}" }
      Bugsnag.notify(e)
    end

    def log_tag
      "[#{@klass_name}] " if @klass_name
    end
  end
end
end
