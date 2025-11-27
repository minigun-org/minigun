# Minigun Compared to Other Libraries

There are many task runner and concurrency libraries available in Ruby and elsewhere.
This guide is intended to help you choose the right tool for your use case.

**Important:** I am not trying to *convince* anyone to use Minigun--in fact,
I recommend Elixir GenStage over Minigun where possible! If I got anything wrong
or mischaracterized any project, please raise a PR to improve this documentation.

## Capability Matrix

| Library / System                           | Type                       | Ruby gem | Triggered in real-time | No persistence required | Pipeline DSL | Batch processing | Telemetry | Multi-machine | Multi-process | Ractors / multi-CPU | Threads / fibers |
|--------------------------------------------|----------------------------|----------|------------------------|-------------------------|--------------|------------------|-----------|---------------|---------------|---------------------|------------------|
| **Minigun**                                | Concurrent pipeline        | ✅        | ❌                      | ✅                       | ✅            | ✅                | ✅         | ❌                | ✅             | 🚧                  | ✅ (threads)      |
| **Elixir GenStage, Flow, Broadway**        | Concurrent pipeline        | ❌        | ✅                      | ✅                       | ✅            | ✅                | ✅         | ✅ (BEAM cluster) | ✅             | ✅                   | ✅ (actors)       |
| **Solid Queue, Sidekiq, etc.**             | Job queue with workers     | ✅        | ✅                      | ❌                       | 🤏           | ❌                | ✅         | ✅                | ✅             | ❌                   | ✅ (threads)      |
| **Kafka, SQS, RabbitMQ**                   | Message queue              | ❌        | ✅                      | ❌                       | ❌            | ❌                | ✅         | ✅                | ✅             | ❌                   | ✅ (workers)      |
| **Karafka (uses Kafka)**                   | Message queue with workers | ✅        | ✅                      | ❌                       | 🤏           | ❌                | ✅         | ✅                | ✅             | ❌                   | ✅ (threads)      |
| **Airflow, Luigi, Prefect, Dagster**       | Workflow orchestrator      | ❌        | 🤏 (event sensors)     | ❌                       | ✅ (DAGs)     | ✅                | ✅         | ✅                | ✅             | ❌                   | ❌                |
| **Parallel**                               | Concurrency abstraction    | ✅        | ❌                      | ✅                       | ❌            | ✅                | ❌         | ❌                | ✅             | ✅                   | ✅ (threads)      |
| **Async + async-container**                | Concurrency primitives     | ✅        | ❌                      | ✅                       | ❌            | ✅                | ❌         | ❌                | ✅             | ❌                   | ✅ (fibers)       |
| **concurrent-ruby**                        | Concurrency primitives     | ✅        | ❌                      | ✅                       | ❌            | ✅                | ❌         | ❌                | ❌             | ❌                   | ✅ (threads)      |
| **Piperator**                              | Pipeline abstraction       | ✅        | ❌                      | ✅                       | ✅            | ✅                | ❌         | ❌                | ❌             | ❌                   | ❌                |
| **Trailblazer::Activity, dry-transaction** | Pipeline abstraction       | ✅        | ❌                      | ✅                       | ✅            | ❌                | ❌         | ❌                | ❌             | ❌                   | ❌                |

### Column Meanings

- **Ruby gem** - The library is written in Ruby and can be easily integrated into a Ruby application.
- **Triggered in real-time** - Processing can be initiated by external events (HTTP/webhooks/messages) with durability and at-least-once semantics.
- **No persistence required** - Does not require a persistent backend datastore such as SQL/Redis/Kafka; OK to run in-memory on one machine.
- **Pipeline DSL** - Has abstractions for composable, multi-stage flows (produce → transform → consume), fan-out/fan-in, and back-pressure.
- **Batch processing** - Efficient for a large, finite dataset processed ASAP (e.g., "email every user today").
- **Telemetry** - Includes monitoring and/or statistics collection which can be used for performance diagnosis and optimization.
- **Multi-machine** - Has abstractions to use for horizontal scaling across hosts (shared broker/coordination, consumer groups).
- **Multi-process** - Has abstractions to use multiple OS processes cleanly (CPU-bound work, COW, avoid GVL).
- **Multi-CPU / ractors** - Has abstractions to use multiple CPU cores in one OS process, e.g. Ruby 3's Ractors.
- **Threads / fibers** - Has abstractions to use single-core concurrency using threads or fibers.

## In-Depth Comparisons

The following Minigun code will be used as a reference throughout these examples.
This code sends a newsletter to all your users using 8 forked processes (`in_cow_forks`)
and 10 consumer threads (`in_threads`) on each process, creating 8 * 10 = 80 threads of parallelism.

```ruby
# Declare the task
task = Minigun.task('newsletter_sender') do

  # Producer: Emits Array<User> (5000 per batch) to next stage
  produce(User.find_in_batches(5_000))

  # Spawn a copy-on-write fork for each batch (max 8 forks at once)
  in_cow_forks(8) do

    # Unpack the Array<User> batches to emit single User objects to next stage
    debatch

    # Spawn 10 worker threads (10 threads on each forked process)
    in_threads(10) do

      # Consumer: Send an email to each user.
      consume do |user|     
        NewsletterMailer.with(user: user).deliver_now
      end
    end
  end
end

# Run the task in a background thread
task.start
```

### Minigun vs. Parallel gem

Parallel gem is a quick tool for executing Ruby enumerator loops (`each`/`map`) with threads
or processes. It's great for simple scenarios, but as a trade-off it lacks some features which
Minigun's more complex DSL provides:
- Multi-stage flow (produce → transform → consume)
- Back-pressure
- Support for COW forking (Parallel's `in_processes` uses IPC marshalling rather than copy-on-write memory.)

```ruby
require 'parallel'

Parallel.each(User.find_in_batches(5_000), in_processes: 8) do |batch|
  batch.each { |u| NewsletterMailer.with(user: u).deliver_now }
end
```

### Minigun vs. Async gem

Async is a composable asynchronous I/O framework for Ruby

Async gem provides concurrency 
Used in combination

and its creator, Samuel Williams, is the author of the Falcon fiber-based webserver
and a top advocate for robust fiber support in the Ruby ecosystem.

Async provides excellent concurrency primitives for using fibers, which are
great for high-IO fan-out. However, it does not contain a higher-level pipeline DSL
abstraction like Minigun. 

    Async do
      producer_task = Async do
        5.times do |i|
          item = "Item #{i}"
          queue.enqueue(item)
          puts "Produced: #{item}"
          sleep(0.1) # Simulate some work
        end
        queue.close # Signal that no more items will be added
      end
    end

Consume (retrieve) items from the queue.
Code

    Async do
      consumer_task = Async do
        while item = queue.dequeue
          puts "Consumed: #{item}"
          sleep(0.2) # Simulate some work
        end
        puts "Consumer finished."
      end
    end


### Minigun vs. async-container

The async-container library, originally written for the Falcon webserver, is a multi-process
supervision tree abstraction which runs isolated workers in each process. Unlike Minigun,
it is not designed to transmit data across process boundaries (i.e. COW or IPC), and is
not designed for pipeline-type flows.

```ruby
require "async"
require "async/queue"
require "async/container"

container = Async::Container.new
container.run(count: 8) do
  queue = Async::Queue.new
  Async do |task|
    task.async do
      # Producers run inside each process. You would need to partition
      # the produced range for each process.
      User.find_each { |u| queue.enqueue u }
      50.times { queue.enqueue :done }
    end

    50.times do
      task.async do
        while (u = queue.dequeue)
          break if u == :done
          NewsletterMailer.with(user: u).deliver_now
        end
      end
    end
  end
end

container.wait
```

### vs. Polyphony gem
Used in combination

https://github.com/digital-fabric/polyphony

https://noteflakes.com/articles/2021-11-13-real-world-polyphony-chat


https://github.com/digital-fabric/polyphony/blob/master/examples/core/stages.rb

```ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'polyphony'

# Based on the design of Elixir's GenStage

class Producer
  def initialize(mod, *a, **b)
    extend(mod)
    setup(*a, **b)
    @_fiber = spin do
      receive_loop do |msg|
        case msg[:kind]
        when :demand
          items = handle_demand(msg[:limit])
          msg[:peer] << items
        end
      end
    end
  end

  def <<(msg)
    @_fiber << msg
  end
end

module Counter
  def setup(counter = 0)
    @counter = counter
  end

  def handle_demand(demand)
    events = (@counter...@counter + demand).to_a
    @counter += demand
    events
  end
end

counter = Producer.new(Counter, 0)

class Consumer
  def initialize(mod, *a, **b)
    extend(mod)
    setup(*a, **b) if respond_to?(:setup)
    @_fiber = spin do
      while true
        items = get_items
        handle_items(items)
      end
    end

    @max_demand = 10
    @min_demand = 5
  end

  def subscribe(upstream)
    @upstream = upstream
  end

  private

  def get_items
    send_demand(@max_demand) if !@sent_demand
    items = receive
    send_demand(@min_demand)
    items
  end

  def send_demand(demand)
    if @upstream
      @upstream << { peer: Fiber.current, kind: :demand, limit: demand }
      @sent_demand = true
    else
      sleep 0.1
    end
  end
end

module Printer
  def handle_items(items)
    sleep 1
    puts "got: #{items.join(' ')}"
  end
end

# counter << { peer: Fiber.current, kind: :demand, limit: 10 }
# r = receive

# p r: r

# counter << { peer: Fiber.current, kind: :demand, limit: 10 }
# r = receive
# p r: r

printer = Consumer.new(Printer)
printer.subscribe(counter)

sleep
```


### Minigun vs. concurrent-ruby gem

Used in combination

concurrent-ruby offers concurrency primitives (executors, futures/promises, channels)
for use within single processes. It does not contain batteries-included pipeline semantics
or multi-process abstractions.

```ruby
require "concurrent-ruby"

pool  = Concurrent::FixedThreadPool.new(20)
queue = SizedQueue.new(200) # back-pressure

prod = Thread.new do
  User.find_each { |u| queue << u }
  20.times { queue << :done }
end

20.times do
  pool.post do
    loop do
      u = queue.pop
      break if u == :done
      NewsletterMailer.with(user: u).deliver_now
    end
  end
end

prod.join
pool.shutdown
pool.wait_for_termination
```



Minigun vs Solid Queue / Sidekiq.
Job queues shine for real-time, durable, per-item work kicked off by app events. For a one-shot “send to everyone now,” they incur heavy enqueue/ack overhead and database/broker pressure. Minigun drops the broker, preloads in big batches, forks, threads, and finishes quickly. Choose queues when you need durability, retries across boxes, and operational visibility of per-item jobs; choose Minigun when you want raw throughput on a finite set with minimal infra.

```ruby
class NewsletterJob
  include Sidekiq::Job
  def perform(user_id)
    user = User.find(user_id)
    NewsletterMailer.with(user: user).deliver_now
  end
end

# enqueue N jobs (durable, but high per-item overhead)
User.find_in_batches(5_000) do |batch|
  batch.each { |u| NewsletterJob.perform_async(u.id) }
end
```


Minigun vs Kafka / SQS / RabbitMQ (brokers).
Brokers give you durability, partitioning, consumer groups, and cross-machine scaling--perfect for continuous streams and event-driven systems. They're not optimized for “process a static dataset and exit.” Minigun runs on a single box (or a few), eliminating the broker round-trip and per-item persistence cost. If your source of truth is a stream and you need at-least-once delivery at scale, pick a broker; if your data is local/queried and you value sheer batch speed, pick Minigun.

unlike job queues, many which use SQL, these queue systems are usually a better purpose-built abstraction for the data layer. But they don't give.

idempotency and replayability is another concern. need to re-inject items in the queue. data lake

Used in combination with minigun


```ruby
# Pseudo Ruby using a generic client: publish IDs, consume and deliver
# Producer:
User.find_in_batches(5_000) do |batch|
  broker_topic.publish(batch.map(&:id)) # Kafka/SQS/RabbitMQ …
end

# Consumer worker:
broker_topic.each_message(concurrency: 32) do |user_id|
  NewsletterMailer.with(user: User.find(user_id)).deliver_now
end
```
Minigun vs Karafka (Kafka on Ruby).
Karafka is a strong Ruby consumer framework: partitions, batching, rebalances, and nice DX for Kafka apps. It's ideal when your workload is inherently streaming and multi-machine. Minigun is simpler and faster for finite batches sourced from your DB/files, leveraging COW forks and threads without Kafka operational overhead. Use Karafka for durable, shared consumption; use Minigun for high-throughput local batch crunching.

```ruby
# Gem: karafka
class NewslettersConsumer < Karafka::BaseConsumer
  def consume
    messages.each do |m|
      u = User.find(m.payload["user_id"])
      NewsletterMailer.with(user: u).deliver_now
    end
  end
end

# Producer elsewhere:
User.find_each { |u| AppProducer.produce_sync(topic: "newsletters", payload: { user_id: u.id }) }
```
Minigun vs Piperator.
Piperator gives you a tidy step/pipeline composition for business logic, but concurrency and scaling are DIY. Minigun keeps the clarity of stages and adds real throughput tools--bounded links, threads, and forks--so you can both express and drain large batches efficiently. If you want purely sequential, testable steps, Piperator is elegant; if you also want cores humming and memory-safe preloading, Minigun is the turnkey option.

```ruby

```
Minigun vs Trailblazer::Activity / dry-transaction.
These are orchestration DSLs for business flows and error routing, not bulk data runners. You'll still need an execution engine (threads/processes, back-pressure, batching). Minigun is that engine. Pair them if you like their control-flow semantics at the step level, but expect Minigun to handle the heavy lifting of draining large enumerables quickly.

```ruby

```
Minigun vs Airflow.
Airflow is a full DAG scheduler/orchestrator with time-based triggers, dependencies, retries, backfills, and lineage. It's superb for multi-system batch ETL where each task is a separate container/script. Minigun is an in-process executor for a single Ruby job that you want to finish blazing fast. Often they complement: Airflow schedules the job; Minigun makes the job itself saturate the box efficiently.

Each Airflow task is run in its
own process, not as a thread within a single process. This design choice is critical for isolation and true parallel execution, especially given Python's Global Interpreter Lock (GIL), which limits true simultaneous multithreading in CPU-bound tasks.
however, there is no memory sharing

Used in combination with minigun

```ruby

```
Minigun vs Luigi.
Luigi is similar in spirit to Airflow but lighter: file/task dependency graphs and idempotent batch pipelines. It's great for orchestrating multi-step offline jobs; it's not an execution accelerator by itself. Minigun accelerates the inner loop on one machine (batches, COW forks, threads). Use Luigi to coordinate tasks and outputs; use Minigun inside a task to process the heavy enumerable quickly.

```ruby

```













### Minigun vs. Elixir GenStage, Flow, and Broadway

If Ruby support isn't required, Elixir has excellent producer–consumer tooling, including GenStage, Flow, and Broadway.
Elixir runs on the Erlang/BEAM VM, which natively utilizes multiple CPU cores per process with lightweight actors
and immutable data, and also makes multi-machine clustering straightforward. If you're doing a green-field project
which will rely heavily on pipelines, you should seriously consider the Elixir ecosystem as a first-choice.

#### Elixir GenStage

GenStage gives you demand-driven producer-consumer pipelines that scale cleanly across BEAM
nodes--great for streaming and high-IO. You can do finite "process N and exit" batches by writing a
bounded producer and checkpointing, but it takes extra scaffolding. <-- this word salad

GenStage shares some design similarities with minigun
Explain Queues (demand) and routing (dispatchers)


```elixir
# mix deps: gen_stage, ecto, etc.
defmodule ScanProducer do
  use GenStage
  def init(_), do: {:producer, %{last_id: 0}}

  def handle_demand(demand, %{last_id: id} = s) do
    rows =
      Repo.all(from u in User, where: u.id > ^id, order_by: u.id, limit: ^demand)
    new_id = (List.last(rows) || %{id: id}).id
    {:noreply, rows, %{s | last_id: new_id}}
  end
end

defmodule MailConsumer do
  use GenStage
  def init(_), do: {:consumer, :ok}
  def handle_events(users, _from, state) do
    Enum.each(users, fn u -> Newsletter.deliver(u) end)
    {:noreply, [], state}
  end
end

{:ok, p} = GenStage.start_link(ScanProducer, :ok)
{:ok, c} = GenStage.start_link(MailConsumer, :ok)
GenStage.sync_subscribe(c, to: p, max_demand: 1000)
```

#### Elixir Flow

Flow is a high-level, parallel data-processing API built on GenStage,
which uses declarative pipeline semantics with Elixir's `|>` pipe operator.

```elixir
# mix deps: {:flow, "~> 1.2"}, {:ecto_sql, ...}, your DB adapter, etc.

import Ecto.Query

defmodule NewsletterBatch do
  @stages System.schedulers_online() * 2
  @max_demand 1_000

  def run do
    query =
      from u in User,
        select: %{id: u.id, email: u.email},
        order_by: u.id

    Repo.transaction(fn ->
      Repo.stream(query)
      |> Flow.from_enumerable(stages: @stages, max_demand: @max_demand)
      |> Flow.partition(stages: @stages, hash: fn %{id: id} -> id end)
      |> Flow.each(fn u -> deliver(u) end)
      |> Flow.run()
    end, timeout: :infinity)
  end

  defp deliver(%{id: id, email: email}) do
    # Your delivery code here (idempotent if re-runs are possible)
    Newsletter.deliver(%{id: id, email: email})
  end
end
```

#### Elixir Broadway

Broadway builds on GenStage with durability and broker adapters (SQS/Rabbit/Kafka),
adding processors/batchers for micro-batching and at-least-once semantics.

```elixir
# deps: broadway + adapter (e.g., broadway_sqs)
defmodule NewslettersPipe do
  use Broadway

  def start_link(_) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producers: [
        default: [
          module: {BroadwaySQS.Producer, queue_url: System.get_env("NEWSLETTER_SQS")},
          stages: 2
        ]
      ],
      processors: [default: [stages: 20]],
      batchers: [mail: [batch_size: 1000, batch_timeout: 500]]
    )
  end

  def handle_message(_, msg, _ctx), do: Broadway.Message.put_batcher(msg, :mail)

  def handle_batch(:mail, messages, _batch_info, _ctx) do
    Enum.each(messages, fn m ->
      uid = m.data["user_id"]
      Newsletter.deliver(load_user(uid))
    end)
    messages
  end
end
```































--------------------
---------------------
--------------------
-----------------------

multi-process
RAFT

The BEAM VM 


Minigun gives you that finite-batch ergonomics (debatch, forks, bounded queues) immediately on Ruby,
great when your data sits in a DB and you want a fast single-job drain.



```ruby

```
Minigun vs Elixir Broadway.



```ruby

```












### Quick guidance
- One-box, maximum throughput, no infra: Minigun / Parallel / concurrent-ruby (choose based on how much pipeline structure you want).
- High-IO pipelines: Async or Polyphony (fibers), optionally add async-container for multi-process.
- Durable events, multi-machine: Kafka family (Karafka) / SQS (Shoryuken) / RabbitMQ (Sneakers/Hutch).
- Business-flow orchestration: Piperator / Trailblazer / dry-transaction (pair with a concurrency runtime when needed).
- If you want, I can generate a “capability radar” graphic and a few code sketches showing the same three-stage pipeline implemented with: Minigun, concurrent-ruby (Channels), and Async(+container).

----------------

\* **Parallel → Composability:** great for data-parallel `each/map` but not a full multi-stage pipeline DSL with built-in back-pressure.

---

```

Does your action need to be near-realtime?

Do you need persistent job queues?
├─ Yes → Use Sidekiq, Resque, or Solid Queue
└─ No → Continue...

Do you need distributed workers across multiple machines?
├─ Yes → Use Sidekiq, Resque, or a distributed queue
└─ No → Continue...

Do you need job scheduling (cron-like features)?
├─ Yes → Use Sidekiq Enterprise, Clockwork, or Whenever
└─ No → Continue...

Do you have multi-stage data processing workflows?
├─ Yes → Minigun is a great fit! ✓
└─ No → Continue...

Do you need to process data in-memory with parallelism?
├─ Yes → Minigun is a great fit! ✓
└─ No → Consider alternatives
```

## Minigun vs Solid Queue, Sidekiq, etc.

### Ruby Job Queues at a Glance

Ruby has a proliferation of job queue systems, including
[Solid Queue](https://github.com/rails/solid_queue),
[Sidekiq](https://github.com/sidekiq/sidekiq),
[Resque](https://github.com/resque/resque),
[GoodJob](https://github.com/bensheldon/good_job),
[Que](https://github.com/que-rb/que),
[Delayed Job](https://github.com/collectiveidea/delayed_job), and
[Delayed](https://github.com/Betterment/delayed),
each compatible with Rails' [Active Job](https://edgeguides.rubyonrails.org/active_job_basics.html) abstraction layer.
These job systems shift work (e.g. sending an email) from being done *synchronously* in a [controller](https://guides.rubyonrails.org/action_controller_overview.html)
to *asynchronous* workers that run outside the web request/response path.

Each of these job queue systems implements the same core design pattern:

1. **Enqueue:** App code enqueues a job record with a small, serializable payload (e.g., user_id) into a "jobs" database table.
2. **Fetch:** Worker processes fetch/poll/pop jobs from that database table.
3. **Perform:** Worker materializes the payload and executes the job, which may include additional database fetching as needed.
4. **Dequeue:** Delete the job record from the table, *or* re-queue if the job failed and we need to retry.

```ruby
# Your controller
class UsersController < ApplicationController
  def sign_up
    user.sign_up!

    # Enqueue a job record
    SendSignUpEmailJob.perform_later(user.id)
  end
end

# Your job class
class SendSignUpEmailJob < ApplicationJob
  queue_as :mailers

  def perform(user_id)
    # Fetch data as needed
    user = User.find_by(id: user_id)
    # Do the actual work
    UserSignUpMailer.with(user: user).sign_up_mail.deliver_now
  end
end
```

The key **advantages** of this design pattern are:

1. **Near real-time response:** A 5–10 second delay to receive an email, etc. after performing a web action is usually invisible to users.
2. **Parallelism, isolation & scaling:** These systems are multi-process and/or multi-threaded, allowing you to run many workers concurrently across many machines, each pulling jobs from the same central database.
3. **Statefulness & retry-ability**: When jobs fail, we can re-enqueue them and attempt them later.

--CLEAN THIS UP--

The **disadvantages** are:

1. **N-query problem**: For N jobs, They perform N queries for N jobs.
2. **Queue backups**: They are prone to queue back-ups. Some job systems have concept of job priority, pools of queues, etc. as mitigation strategies for this.
3. **Database bottleneck, resource utilization**: These systems require a database, catastrophic failure
4. **Atomic by design**:

N-query overhead: For N jobs, you often issue ~N DB/queue operations (enqueue, fetch/ack), which adds load at scale.
Queue backlogs: Susceptible to head-of-line blocking during spikes. (Mitigate with priorities, multiple queues, sharding, and concurrency limits.)
Database bottleneck & blast radius: DB-backed queues can become the throughput bottleneck and a single point of failure if not replicated/observed. (Use proper indexing, tuning, replicas, and redundancy.)

### What if we don't need real-time?

Consider a different use case: sending a weekly newsletter to *all* our users at once.
Here we aren't concerned about being perfectly "real-time"; instead we're concerned about
the overall volume of actions that must be done (given a large number of users), and we'd
just like to send *as quickly and efficiently as possible*.

We might start by using our trusty queue system:

```ruby
User.find_each do |user|
  NewsletterMailer.with(user: user).deliver_later
end
```

Supposing we have N=1,000,000 users, given that we might have a worker pool of X=4 machines,
Y=8 worker processes (typically matching Y CPU cores on each machine), and Z=10 threads per
process, each thread will only need to process N / (X * Y * Z) = 3,125 jobs, so we'll crank through it quickly.

But **what about our database?** This setup will require us to:
1. Enqueue N=1,000,000 rows to our jobs table (SQL or Redis).
2. Perform N*M fetch queries to our main database (SQL), where M is the number of queries inside the job.
3. Delete those N jobs after we're done with each.

Redis-based queues such as Sidekiq, will handle this volume better than SQL databases,
but still, we can do much better by **removing the database** entirely.

### DIY Threading in Ruby

Let's first implement this using multi-threading. Starting with a naive implementation:

```ruby
User.find_in_batches(10_000) do |users|
  Thread.new do
    users.each { |user| NewsletterMailer.with(user: user).deliver_now }
  end
end
```

Here we use batch size B=10,000 to create N / B = 100 threads to send the mails. The core problem
with this implementation is that we will **load all N=1,000,000 users** into Ruby's memory, likely causing
our process to Out-Of-Memory (OOM) crash.

To solve this, let's add a thread pool:

```ruby
# Plain ol' Ruby
THREAD_POOL_SIZE = 10
threads = []
User.find_in_batches(1000) do |users|
  threads << Thread.new do
    users.each { |user| NewsletterMailer.with(user: user).deliver_now }
  end
  threads.shift.join while threads.size >= THREAD_POOL_SIZE
end
threads.each(&:join)

# Or using concurrent-ruby gem
pool = Concurrent::FixedThreadPool.new(10)
User.find_in_batches(1000) do |users|
  pool.post do
    users.each { |user| NewsletterMailer.with(user: user).deliver_now }
  end
end
pool.shutdown
pool.wait_for_termination
```

Now we're loading up to T=10 threads, each with B=1,000 user objects, meaning a tolerable
T * B = 10,000 objects loaded at any given time. **But** since we're on just **one process** on one machine
(= one CPU core, since we're bound by [Ruby's GVL](https://rubykaigi.org/2023/presentations/KnuX.html)),
each thread must process 100,000 objects--unfortunately nowhere near the parallelism we had with our job queue!

### Time to bring in Minigun!

First, let's implement a functionally identical thread pool pattern with Minigun:

```ruby
task = Minigun.pipeline do
  # Use enumerator as arg to iterate and emit each User object
  produce(User.find_each)

  consume(threads: 10) do |user|
    NewsletterMailer.with(user: user).deliver_now
  end
end

task.start
```

Already, Minigun's declarative syntax makes it far easier to grok what's going on.

...but we're not done yet! Now let's engage *all CPU cores on our machine*,
using a COW (Copy-on-Write) forking pattern.

```ruby
task = Minigun.pipeline do
  # Use #find_in_batches to emit Array<User>
  produce(User.find_in_batches(5_000))

  # Create up to 8 child processes at once
  cow_forks(8) do
    # Re-emit the Array<User> batches as individual User objects
    debatch

    consume(threads: 10) do |user|
      UserReminderMailer.with(user: user).deliver_now
    end
  end
end

task.start
task.hud # Watch it in action! 🍿
```

Each time our producer stage emits an `Array<User>` with B=5,000 user objects, Minigun
will keep that array in Ruby's allocated RAM memory, then
[fork a child process](https://man7.org/linux/man-pages/man2/fork.2.html) that will
read and consume that Array from the same memory *without copying*.
This is both very fast and memory efficient; with F=8 forks we'll only load
B * F = 40,000 user objects into memory at a time. Each fork will have T=10 threads,
achieving F * T = 80 threads of parallelism.

This is also *memory safe* to do. The `Array<User>` objects themselves shouldn't be mutated,
but even if they are, since we've used COW (Copy-on-Write) forking any writes will be written
to *new memory addresses* accessed only by the process instance which wrote the change.

Granted, unlike our job queue system we're still only executing on one machine, but given
that we've eliminated N-item database fetching, we'll be executing *much faster* overall.

### Non-Ruby Alternatives

Amazon SQS, Kafka, AWS Lambda

the pattern is the same--you are paying for atomiticy with $$$


https://github.com/trailblazer/trailblazer-activity


require "parallel"

Parallel.each(User.find_in_batches(5_000), in_processes: 8) do |batch|
batch.each { |u| NewsletterMailer.with(user: u).deliver_now }
end

# 2 CPUs -> work in 2 processes (a,b + c)
results = Parallel.map(['a','b','c']) do |one_letter|
SomeClass.expensive_calculation(one_letter)
end

# 3 Processes -> finished after 1 run
results = Parallel.map(['a','b','c'], in_processes: 3) { |one_letter| SomeClass.expensive_calculation(one_letter) }

# 3 Threads -> finished after 1 run
results = Parallel.map(['a','b','c'], in_threads: 3) { |one_letter| SomeClass.expensive_calculation(one_letter) }

# 3 Ractors -> finished after 1 run
results = Parallel.map(['a','b','c'], in_ractors: 3, ractor: [SomeClass, :expensive_calculation])



Async (socketry) + async-container
Structured concurrency on fibers with an ergonomic scheduler; async-container adds multi-process workers (a decent stand-in for Minigun's fork stage). Great for IO-heavy pipelines.



If the “pipeline” is really a stream processor:

Karafka (Kafka) -- robust consumer groups, back-pressure, batching, and concurrency; great for large fan-out workloads.

Racecar / ruby-kafka -- lighter-weight Kafka consumers.

Sneakers / Hutch -- RabbitMQ consumers with worker pools.

Shoryuken -- SQS workers with concurrency control.


Functional/flow “pipelines” (control-flow, not concurrency)

Useful when you like Minigun's stage-by-stage clarity but don't need parallelism built in:

Piperator, dry-transaction, Trailblazer::Activity -- compose business steps, add retries, error routing, etc. You can pair these with concurrent-ruby/Async to get both clarity and throughput.



How to choose

You want Minigun-style “one machine, all cores, simple code” → Start with Parallel (in_processes) or Async + async-container.

You want explicit producer/consumer ergonomics inside one process → concurrent-ruby (Channels + fixed pools) or Async (Queues).

You want COW efficiency on big preloaded batches → Preload → fork (or Parallel in processes) and keep objects immutable in children.

You want durability/retries across boxes → Kafka/RabbitMQ/SQS stack (Karafka/Sneakers/Shoryuken).

You want declarative business flows, then add parallelism later → Piperator / dry-transaction / Trailblazer + a concurrency runtime.

If you tell me which Minigun traits you rely on most (e.g., COW forks, HUD/telemetry, debatching, back-pressure), I can sketch a drop-in recipe using one of the above.



## Hybrid Approach

Use both Minigun and Sidekiq together for the best of both worlds:

```ruby
# Sidekiq handles scheduling and persistence
class ProcessDataJob < ApplicationJob
  queue_as :data_processing

  def perform(dataset_id)
    dataset = Dataset.find(dataset_id)

    # Minigun handles complex multi-stage processing
    class DataPipeline
      include Minigun::DSL

      pipeline do
        producer :extract { dataset.records.find_each { |r| emit(r) } }
        processor :transform, threads: 10 { |r, output| output << transform(r) }
        processor :enrich, threads: 20 { |r, output| output << enrich(r) }
        accumulator :batch, max_size: 500 { |batch| emit(batch) }
        consumer :load, threads: 4 { |batch| bulk_insert(batch) }
      end
    end

    DataPipeline.new.run
  end
end

# Schedule with Sidekiq
ProcessDataJob.set(wait: 1.hour).perform_later(dataset.id)
```

### The Future: IPC Forking, Ractors, and Multi-Machine

Ruby 3.5 brings a mature implementation 

However, even with Ractors, 
each Ractor has it
that we must copy memory before we read it.
network, [Raft concensus algorithm](https://raft.github.io/)


TO ADD: See recipies



# --------------------------------
BELOW THIS LINE, MOVE TO RECIPIES

## Minigun's Sweet Spot

### ✅ Use Minigun When:

#### 1. In-Memory Data Processing

**Perfect for:**
```ruby
# ETL pipeline that runs to completion
class DataMigration
  include Minigun::DSL

  pipeline do
    producer :extract { LegacyDB.find_each { |r| emit(r) } }
    processor :transform, threads: 10 { |r, output| output << transform(r) }
    consumer :load { |r| NewDB.insert(r) }
  end
end
```

#### 2. Multi-Stage Workflows

**Perfect for:**
```ruby
# Complex pipeline with multiple transformation steps
pipeline do
  producer :fetch { fetch_data }
  processor :clean, threads: 5 { |data, output| output << clean(data) }
  processor :validate { |data, output| output << validate(data) }
  processor :enrich, threads: 20 { |data, output| output << enrich(data) }
  accumulator :batch, max_size: 100 { |batch, output| output << batch }
  consumer :save, threads: 4 { |batch| save_batch(batch) }
end
```

#### 3. Batch Processing

**Perfect for:**
```ruby
# Process large datasets efficiently
class BatchJob
  include Minigun::DSL

  pipeline do
    producer :stream { Record.find_each(batch_size: 1000) { |r| emit(r) } }
    processor :process, execution: :cow_fork, max: 8 { |r| process(r) }
    accumulator :batch, max_size: 500 { |batch| emit(batch) }
    consumer :save { |batch| bulk_insert(batch) }
  end
end
```

#### 4. Web Scraping & Crawling

**Perfect for:**
```ruby
# Parallel web scraping
pipeline do
  producer :urls { urls.each { |url| emit(url) } }
  processor :fetch, threads: 20 { |url, output| output << HTTP.get(url) }
  processor :parse, threads: 5 { |html, output| output << parse(html) }
  consumer :save { |data| save_to_db(data) }
end
```

#### 5. Data Enrichment

**Perfect for:**
```ruby
# Enrich data from multiple sources
pipeline do
  producer :users { User.find_each { |u| emit(u) } }

  # Fan-out to multiple APIs
  processor :split, to: [:api_a, :api_b, :api_c] { |user, output| output << user }

  processor :api_a, to: :merge, threads: 20 { |user| fetch_api_a(user) }
  processor :api_b, to: :merge, threads: 20 { |user| fetch_api_b(user) }
  processor :api_c, to: :merge, threads: 20 { |user| fetch_api_c(user) }

  # Fan-in to merge results
  processor :merge { |result| combine_and_save(result) }
end
```

### ❌ Don't Use Minigun When:

#### 1. You Need Persistence

**Use Sidekiq instead:**
```ruby
# Jobs survive server restarts
class UserEmailJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    user = User.find(user_id)
    UserMailer.welcome_email(user).deliver_now
  end
end
```

**Why Sidekiq?**
- Jobs stored in Redis (survive crashes)
- Can retry failed jobs days later
- Workers can restart without losing jobs

#### 2. You Need Distribution

**Use Sidekiq/Resque instead:**
```ruby
# Workers across multiple machines
# Machine 1: Web server enqueues
UserEmailJob.perform_later(user.id)

# Machine 2-5: Workers process
# Each machine runs: bundle exec sidekiq
```

**Why Sidekiq?**
- Redis acts as central queue
- Workers on any machine
- Scale horizontally

#### 3. You Need Scheduling

**Use Sidekiq Enterprise or Clockwork:**
```ruby
# Scheduled jobs
class DailyReportJob < ApplicationJob
  def perform
    generate_and_send_report
  end
end

# config/schedule.rb
every 1.day, at: '6:00 am' do
  DailyReportJob.perform_later
end
```

**Why Sidekiq Enterprise?**
- Cron-like scheduling
- Recurring jobs
- Calendar-based execution

#### 4. Jobs Run for Hours/Days

**Use a persistent queue:**
```ruby
# Very long-running job
class BigDataProcessingJob < ApplicationJob
  def perform
    # Takes 8 hours
    process_terabytes_of_data
  end
end
```

**Why persistent queue?**
- If server restarts, job resumes
- Can monitor progress
- Retry on failure

## Core Differences: Minigun vs Sidekiq

### 1. Persistence

**Sidekiq:**
```ruby
# Jobs stored in Redis
class WelcomeEmailJob < ApplicationJob
  def perform(user_id)
    UserMailer.welcome_email(user_id).deliver
  end
end

WelcomeEmailJob.perform_later(user_id)

# If server crashes:
# - Job survives in Redis
# - Worker picks it up when restarted
# - No data loss
```

**Minigun:**
```ruby
# Runs in memory
class EmailPipeline
  include Minigun::DSL

  pipeline do
    producer :users { User.find_each { |u| emit(u) } }
    processor :generate { |user, output| output << generate_email(user) }
    consumer :send { |email| send_email(email) }
  end
end

EmailPipeline.new.run

# If server crashes:
# - Pipeline stops
# - In-flight items lost
# - Must restart from beginning
```

**Winner:** Sidekiq for jobs that must survive crashes.

### 2. Multi-Stage Processing

**Minigun:**
```ruby
# Natural multi-stage pipeline
pipeline do
  producer :extract { LegacyDB.find_each { |r| emit(r) } }
  processor :clean, threads: 10 { |r, output| output << clean(r) }
  processor :validate { |r, output| output << validate(r) }
  processor :enrich, threads: 20 { |r, output| output << enrich(r) }
  accumulator :batch, max_size: 500 { |batch| emit(batch) }
  consumer :load, threads: 4 { |batch| insert_many(batch) }
end

# All stages defined in one place
# Data flows automatically
# Can monitor entire pipeline
```

**Sidekiq:**
```ruby
# Must chain jobs manually
class ExtractJob < ApplicationJob
  def perform
    LegacyDB.find_each do |record|
      CleanJob.perform_later(record)
    end
  end
end

class CleanJob < ApplicationJob
  def perform(record)
    cleaned = clean(record)
    ValidateJob.perform_later(cleaned)
  end
end

class ValidateJob < ApplicationJob
  def perform(record)
    validated = validate(record)
    EnrichJob.perform_later(validated)
  end
end

# ... more jobs ...

# Jobs are separate
# Hard to see full workflow
# Must manage state externally
```

**Winner:** Minigun for multi-stage workflows.

### 3. Parallelism Models

**Minigun:**
```ruby
pipeline do
  # Threads for I/O-bound work
  processor :fetch_api, threads: 50 do |id, output|
    output << HTTP.get("https://api.example.com/#{id}")
  end

  # COW forks for CPU-bound work with large data
  processor :process_image, execution: :cow_fork, max: 8 do |image, output|
    output << @model.predict(image)  # Model shared via COW
  end

  # IPC forks for long-running workers
  processor :ml_inference, execution: :ipc_fork, max: 4 do |data, output|
    @model ||= load_expensive_model  # Loaded once per worker
    output << @model.predict(data)
  end
end
```

**Sidekiq:**
```ruby
# Threads only (subject to GVL)
class MyJob < ApplicationJob
  sidekiq_options concurrency: 25  # Max threads

  def perform(id)
    # CPU-intensive work limited by GVL
    # Can't use fork (loses Redis connection)
    expensive_computation(id)
  end
end
```

**Winner:** Minigun for CPU-intensive work or mixed workloads.

### 4. Distribution

**Sidekiq:**
```ruby
# Machine 1 (Web server)
UserEmailJob.perform_later(user.id)

# Machine 2-10 (Workers)
# Each runs: bundle exec sidekiq

# Jobs distributed automatically via Redis
# Scale horizontally by adding machines
```

**Minigun:**
```ruby
# Single machine only
# All stages run within one process tree
# Cannot distribute across machines
```

**Winner:** Sidekiq for distributed systems.

### 5. Observability

**Minigun:**
```ruby
require 'minigun/hud'

# Real-time terminal UI
Minigun::HUD.run_with_hud(MyPipeline)

# Shows:
# - Live throughput per stage
# - Latency percentiles
# - Bottleneck detection
# - Animated data flow
# - Per-stage statistics
```

**Sidekiq:**
```ruby
# Web UI (requires rack)
require 'sidekiq/web'
mount Sidekiq::Web => '/sidekiq'

# Shows:
# - Queue depths
# - Job history
# - Failed jobs
# - Worker status
# - Requires browser
```

**Winner:** Tie - Different styles for different needs.

## Use Case Examples

### ✅ Good Fit: ETL Pipeline

**Scenario:** Migrate 1M records from legacy DB to new system.

**Why Minigun:**
- Runs once, doesn't need persistence
- Multi-stage pipeline (extract → transform → load)
- Needs parallelism (threads for I/O, forks for CPU)
- Can monitor progress with HUD
- No infrastructure needed

```ruby
class DataMigration
  include Minigun::DSL

  pipeline do
    producer :extract { LegacyDB.find_each { |r| emit(r) } }
    processor :clean, threads: 10 { |r, output| output << clean(r) }
    processor :transform, execution: :cow_fork, max: 8 { |r| transform(r) }
    accumulator :batch, max_size: 500 { |batch| emit(batch) }
    consumer :load, threads: 4 { |batch| NewDB.insert_many(batch) }
  end
end

Minigun::HUD.run_with_hud(DataMigration)
```

### ❌ Bad Fit: Background Jobs

**Scenario:** Send welcome email when user signs up.

**Why Sidekiq:**
- Needs persistence (what if server restarts?)
- Single-stage job (just send email)
- Distributed workers (multiple app servers)
- Want retries over days if email fails

```ruby
# Use Sidekiq instead
class WelcomeEmailJob < ApplicationJob
  retry_on Net::SMTPError, wait: :exponentially_longer

  def perform(user_id)
    user = User.find(user_id)
    UserMailer.welcome_email(user).deliver_now
  end
end

# Survives restarts, retries, distributed
WelcomeEmailJob.perform_later(user.id)
```

### ✅ Good Fit: Web Scraper

**Scenario:** Scrape 10,000 product pages nightly.

**Why Minigun:**
- Runs to completion (doesn't need persistence)
- Multi-stage (fetch → parse → extract → save)
- High parallelism (20 threads fetching)
- Monitor with HUD
- No infrastructure

```ruby
class ProductScraper
  include Minigun::DSL

  pipeline do
    producer :urls { Product.pluck(:url).each { |url| emit(url) } }
    processor :fetch, threads: 20 { |url, output| output << HTTP.get(url) }
    processor :parse, threads: 5 { |html, output| output << parse(html) }
    consumer :save { |data| Product.update_data(data) }
  end
end
```

**Benefits:**
- Sidekiq: Scheduling, persistence, distribution
- Minigun: Complex pipelines, parallelism, monitoring
- Use right tool for each part

## Key Takeaways

### Choose Minigun for:
- ✅ In-memory data processing
- ✅ Multi-stage pipelines
- ✅ Batch processing
- ✅ ETL workflows
- ✅ One-off data transformations
- ✅ Development and testing

### Choose Sidekiq/Resque for:
- ✅ Persistent background jobs
- ✅ Distributed processing
- ✅ Job scheduling
- ✅ Long-running jobs
- ✅ Retry over days/weeks
- ✅ Production web apps

### Hybrid Approach:
- Use Sidekiq to schedule and persist jobs
- Use Minigun inside jobs for complex processing

## Next Steps

- [Guides: Introduction](guides/01_introduction.md) - Learn Minigun
- [Recipes](recipes/) - See Minigun in action

---

**Still unsure?** Check out the [Recipes](recipes/) to see if your use case matches.
