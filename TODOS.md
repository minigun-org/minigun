ADD to README:
- stages route to each other sequentially, unless you add :to or :from keywords
- execute in paralle, and do NOT route to each other, unless unless you add :to or :from keywords.

===============================

OK. wait, what if we changed it so:

- every consumer has an input queue
- if there is fan-out (multiple consumers for any 1 producer), add producer output queues and an intermediate router (load balancer) object. the router has an input queue and round-robin allocates to the consumers.
- fan-in without fan-out (i.e. a producer connects to 1 consumer, even if MULTIPLE producers connect to that consumer) is done by directly having the producer insert to the consumer's queue
- emit_to_stage emits DIRECTLY to the consumer input queue

===============================

configurable queue length


=========================

result.is_a?(Hash) && result.key?(:item) && result.key?(:target)

--> tmake this a signal

====================================

weighted routing (load balancing)

==================================

- config
- hooks
- readme
- ractors

==================================

OK. wait, what if we changed it so:

- every producer has an output queue
- every consumer has an input queue
- routers (disapatchers) exist to connect output to inputs
- emit_to_stage emits DIRECTLY to the consumer input queue
- SINGLE queue can be queues if the producer to consumer is 1-to-1 (i.e. just the consumer queue)

===================================


multi-parents --> how do we know end of queues?


redundant with stats, stats should use Concurrent::AtomicFixnum no?
      @produced_count = Concurrent::AtomicFixnum.new(0)
      @in_flight_count = Concurrent::AtomicFixnum.new(0)
      @accumulated_count = 0

stats needs IPC back to parent
are there reliability issues with IPC
consider threading model vs fork model, we have lots of thread spawn/join we need an abstraction for concurrent execution -- ractor, thread, fork

      if has_multi_pipeline?
        # Multi-pipeline mode: run all named pipelines
        run_multi_pipeline(context)
      else
        # Single-pipeline mode: run root pipeline
        @root_pipeline.run(context)
      end



from keyword in pipelines (connects pipelines)
from keyword in stages
ensure that to and from don't create circular deps, but allow it to be somewhat liberal


pipeline to stage
stage to pipeline
pipeline from stage
stage from pipeline

    def promote_nested_to_multi_pipeline(name) <-- this is weird

ipc, process, etc. for childs in dag

pipeline routing to a stage inside another pipeline double nested

emit_to_stage
consume_from_stage
produce as an alias to emit
produce_to_stage


move stats tracking from runner to task

verbose logging of fork, etc

logging of

custom stage types



wait for last forked process to finish

hooks or lifecycle
hooks prepend

- options
  - min_threads
  - max_threads
  - max_processes
  - max_ractors

- execution summary clean output
- print dag to mermaid


  -
  - use IPC to transmit back to parent process


Now in the DSL lets make producer method validate that block arity is zero
consumer validate that block arity >= 1
processor is alias to consumer

then add specs for the same



Strategies:
Stream (continuous): :threaded, :fork_ipc, :ractor
Spawn (per batch): :spawn thread, :spawn_fork, :spawn_ractor


auto_start = false
trigger(:stage)


      # Backward compatibility aliases
      alias fork_accumulate spawn_fork
      alias cow_fork spawn_fork
      alias ipc_fork consumer  # ipc_fork was just a consumer with different execution


remove these:

  # Spawn strategies (require preceding accumulator stage)
  def spawn_thread(name = :consumer, options = {}, &block)
    _minigun_task.add_stage(:consumer, name, options.merge(strategy: :spawn_thread), &block)
  end

  def spawn_fork(name = :consumer, options = {}, &block)
    _minigun_task.add_stage(:consumer, name, options.merge(strategy: :spawn_fork), &block)
  end

  def spawn_ractor(name = :consumer, options = {}, &block)
    _minigun_task.add_stage(:consumer, name, options.merge(strategy: :spawn_ractor), &block)
  end


name = :accumulator


SpawnFork

SpawnRactor

threaded --> spawn_threads
ractor_accumulate --> spawn_ractors
fork_accumulate --> spawn_forks


rename implicit_pipeline to root_pipeline

these should be pipeline-level scoped limits (or global if at root_pipeline)

  max_threads: config[:max_threads] || 5,
  max_processes: config[:max_processes] || 2,
  max_retries: config[:max_retries] || 3,

they should constrain child events, BUT we should allow at least one thread/process for each stage, and log a warning once if the stage has an explicit value set but it's constrained by the global limit

back-pressure?


        accumulator_max_single: config[:accumulator_max_single] || 2000,
        accumulator_max_all: config[:accumulator_max_all] || 4000,
        accumulator_check_interval: config[:accumulator_check_interval] || 100,
        use_ipc: config[:use_ipc] || false


        accumulator_max_single: config[:accumulator_max_single] || 2000,
        accumulator_max_all: config[:accumulator_max_all] || 4000,
        accumulator_check_interval: config[:accumulator_check_interval] || 100,
        use_ipc: config[:use_ipc] || false


        accumulator_max_single: config[:accumulator_max_single] || 2000,
        accumulator_max_all: config[:accumulator_max_all] || 4000,
        accumulator_check_interval: config[:accumulator_check_interval] || 100,
        use_ipc: config[:use_ipc] || false


classy stages
  - classy usage (Pipeline, Stage, etc. by themselves) --> also add to readme


nested pipelines

accumulator

test ipc forking and ractor stuff

mine old code for ideas

everything should be a stage

new_task.instance_variable_set(:@config, parent_task.config.dup)
new_task.instance_variable_set(:@implicit_pipeline, parent_task.implicit_pipeline) # Share the pipeline



let's think about the hooks DSL

  # Pipeline-level fork hooks (apply to all consumers)
  before_fork do
    disconnect_database!
  end

  after_fork do
    reconnect_database!
  end


test that this applies to ALL children in the pipeline

after_each_fork???

after_each??

rescue_error ?

:class, error or standard error


on_error ?
