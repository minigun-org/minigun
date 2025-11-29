# frozen_string_literal: true

module Minigun
  module Cluster
    # Base class for work distribution strategies
    # Subclasses implement different delivery guarantees
    class Distributor
      def initialize(workers:, stage_name:, stage_stats: nil)
        @workers = workers
        @stage_name = stage_name
        @stage_stats = stage_stats
        @worker_index = 0
        @mutex = Mutex.new
      end

      # Main distribution loop - reads from input_queue, writes to output_queue
      def distribute(input_queue, output_queue)
        raise NotImplementedError, 'Subclasses must implement #distribute'
      end

      protected

      # Select next worker (round-robin)
      def next_worker
        @mutex.synchronize do
          worker = @workers[@worker_index % @workers.size]
          @worker_index += 1
          worker
        end
      end

      # Select next worker with increment (for retries to different worker)
      def next_worker_for_retry
        @mutex.synchronize do
          @worker_index += 1
          @workers[@worker_index % @workers.size]
        end
      end

      def log_info(msg)
        Minigun.logger.info "[Cluster] #{msg}"
      end

      def log_warn(msg)
        Minigun.logger.warn "[Cluster] #{msg}"
      end

      def log_error(msg)
        Minigun.logger.error "[Cluster] #{msg}"
      end
    end

    # At-most-once delivery: items may be lost on worker failure, never duplicated
    # Simple fire-and-forget with result collection
    class AtMostOnceDistributor < Distributor
      def distribute(input_queue, output_queue)
        pending_count = 0
        all_sent = false
        mutex = Mutex.new
        done_cv = ConditionVariable.new
        results_queue = Queue.new

        # Collector thread
        collector_thread = Thread.new do
          loop do
            break if mutex.synchronize { pending_count <= 0 && all_sent }

            begin
              result = results_queue.pop(true)
              case result[:type]
              when :results
                result[:results].each { |r| output_queue << r }
                @stage_stats&.record_latency(result[:latency]) if result[:latency]
              when :error
                log_error "Worker error: #{result[:error][:message]}"
              end
              mutex.synchronize do
                pending_count -= 1
                done_cv.signal if pending_count <= 0 && all_sent
              end
            rescue ThreadError
              sleep 0.01
            end
          end
        end

        # Distribution loop
        loop do
          item = input_queue.pop
          break if item.is_a?(Minigun::EndOfStage) && mutex.synchronize { all_sent = true }

          mutex.synchronize { pending_count += 1 }
          worker = next_worker

          Thread.new(worker, item, @stage_name, results_queue) do |w, work_item, stage_name, rq|
            start_time = Time.now
            begin
              results = w[:proxy].process_item(stage_name, work_item)
              rq << { type: :results, results: results, latency: Time.now - start_time }
            rescue StandardError => e
              rq << { type: :error, error: { message: e.message } }
            end
          end
        end

        mutex.synchronize { done_cv.wait(mutex, 1) until pending_count <= 0 }
        collector_thread.join
      end
    end

    # At-least-once delivery: items are retried on failure; duplicates possible
    # Tracks in-flight items and requeues on failure
    #
    # Architecture:
    # - Main thread: reads from input_queue (blocking) and submits to workers
    # - Retry thread: monitors retry queue and resubmits failed items
    # - Collector thread: processes results and signals completion
    class AtLeastOnceDistributor < Distributor
      def initialize(workers:, stage_name:, stage_stats: nil, max_retries: 3)
        super(workers: workers, stage_name: stage_name, stage_stats: stage_stats)
        @max_retries = max_retries
      end

      def distribute(input_queue, output_queue)
        @tracker = DeliveryTracker.new(max_retries: @max_retries)
        @done_cv = ConditionVariable.new
        @results_queue = Queue.new
        @all_sent = false
        @output_queue = output_queue
        @stop_retry_thread = false

        # Collector thread - processes results from workers
        collector_thread = Thread.new { run_collector }

        # Retry thread - handles resubmitting failed items
        retry_thread = Thread.new { run_retry_sender }

        # Main distribution loop - reads from input and sends to workers
        loop do
          item = input_queue.pop

          if item.is_a?(Minigun::EndOfStage)
            @mutex.synchronize { @all_sent = true }
            break
          end

          # Track and send new item
          worker = next_worker
          item_id = @tracker.track(item, worker_uri: worker[:uri])
          submit_item(worker, item, item_id)
        end

        # Stop retry thread and wait for all in-flight items
        @mutex.synchronize do
          @stop_retry_thread = true
          @done_cv.wait(@mutex, 0.5) until @tracker.all_complete?
        end

        retry_thread.join
        collector_thread.join
      end

      private

      def run_retry_sender
        loop do
          should_stop = @mutex.synchronize { @stop_retry_thread && @tracker.all_complete? }
          break if should_stop

          # Process any pending retries
          retry_data = @tracker.next_retry
          if retry_data
            send_retry(retry_data)
          else
            sleep 0.01
          end
        end
      end

      def run_collector
        loop do
          done = @mutex.synchronize { @tracker.all_complete? && @all_sent }
          break if done

          begin
            result = @results_queue.pop(true)
            handle_result(result)
          rescue ThreadError
            sleep 0.01
          end
        end
      end

      def handle_result(result)
        case result[:type]
        when :success
          item_id = result[:item_id]
          if @tracker.complete(item_id)
            result[:results].each { |r| @output_queue << r }
            @stage_stats&.record_latency(result[:latency]) if result[:latency]
          end
          @mutex.synchronize { @done_cv.signal if @tracker.all_complete? && @all_sent }

        when :failure
          item_id = result[:item_id]
          status = @tracker.fail(item_id, error: result[:error])

          case status
          when :retry
            log_warn "Worker #{result[:worker_uri]} failed for item #{item_id}, retrying: #{result[:error]}"
          when :exhausted
            log_error "Item #{item_id} failed after #{@max_retries} retries, giving up"
          end

          @mutex.synchronize { @done_cv.signal if @tracker.all_complete? && @all_sent }
        end
      end

      def send_retry(retry_data)
        item_id = retry_data[:item_id]
        item = retry_data[:item]
        retries = retry_data[:retries]

        worker = next_worker_for_retry
        @tracker.update_for_retry(item_id, item: item, worker_uri: worker[:uri], retries: retries)
        submit_item(worker, item, item_id)
      end

      def submit_item(worker, item, item_id)
        Thread.new(worker, item, item_id, @stage_name, @results_queue) do |w, work_item, id, sname, rq|
          start_time = Time.now
          begin
            results = w[:proxy].process_item(sname, work_item)
            rq << { type: :success, item_id: id, results: results, latency: Time.now - start_time }
          rescue StandardError => e
            rq << { type: :failure, item_id: id, worker_uri: w[:uri], error: e.message }
          end
        end
      end
    end

    # Factory method to create appropriate distributor
    def self.create_distributor(delivery_mode:, workers:, stage_name:, stage_stats: nil, max_retries: 3)
      case delivery_mode
      when :at_most_once
        AtMostOnceDistributor.new(workers: workers, stage_name: stage_name, stage_stats: stage_stats)
      when :at_least_once
        AtLeastOnceDistributor.new(
          workers: workers, stage_name: stage_name, stage_stats: stage_stats, max_retries: max_retries
        )
      else
        raise ArgumentError, "Unknown delivery_mode: #{delivery_mode}"
      end
    end
  end
end
