require 'spec_helper'

RSpec.describe Minigun::Stages::Base do
  let(:task) { double("Task", _minigun_hooks: {}) }
  let(:pipeline) { double("Pipeline", task: task, job_id: "test_job", send_to_next_stage: nil) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:config) { { logger: logger } }
  let(:stage_name) { "test_stage" }
  
  subject { described_class.new(stage_name, pipeline, config) }

  describe "#initialize" do
    it "sets up the stage with the correct attributes" do
      expect(subject.name).to eq(stage_name)
      expect(subject.config).to eq(config)
    end
  end

  describe "#process" do
    it "raises NotImplementedError" do
      expect { subject.process("test") }.to raise_error(NotImplementedError)
    end
  end

  describe "#emit" do
    let(:item) { "test_item" }
    
    it "sends the item to the next stage in the pipeline" do
      # Create a mock method for send_to_next_stage that has arity 3
      allow(pipeline).to receive(:method).with(:send_to_next_stage).and_return(
        double("send_to_next_stage_method", arity: 3)
      )
      expect(pipeline).to receive(:send_to_next_stage).with(subject, item, :default)
      subject.emit(item)
    end

    it "supports legacy interface with arity 2" do
      # Create a mock method for send_to_next_stage that has arity 2
      allow(pipeline).to receive(:method).with(:send_to_next_stage).and_return(
        double("send_to_next_stage_method", arity: 2)
      )
      expect(pipeline).to receive(:send_to_next_stage).with(subject, item)
      subject.emit(item)
    end
  end

  describe "#on_start" do
    it "logs the start of the stage" do
      expect(logger).to receive(:info).with("[Minigun:test_job][test_stage] Stage starting")
      subject.on_start
    end
  end

  describe "#on_finish" do
    it "logs the finish of the stage" do
      expect(logger).to receive(:info).with("[Minigun:test_job][test_stage] Stage finished")
      subject.on_finish
    end
  end

  describe "#on_error" do
    it "logs the error" do
      error = StandardError.new("Test error")
      expect(logger).to receive(:error).with("[Minigun:test_job][test_stage] Error: Test error")
      subject.on_error(error)
    end
  end

  describe "hooks" do
    let(:before_hook) { proc { @called = true } }
    let(:after_hook) { proc { @finished = true } }
    let(:error_hook) { proc { |err| @error = err } }
    
    context "when task has hooks defined" do
      let(:task) do
        task = double("Task")
        allow(task).to receive(:class).and_return(
          double("TaskClass", 
                 _minigun_hooks: {
                   before_test_stage: [{ if: nil, unless: nil, block: before_hook }],
                   after_test_stage: [{ if: nil, unless: nil, block: after_hook }],
                   on_error_test_stage: [{ if: nil, unless: nil, block: error_hook }]
                 },
                 respond_to?: true)
        )
        allow(task).to receive(:instance_exec) { |*args, &block| block.call(*args) }
        task
      end

      it "calls before stage hooks on start" do
        expect(task).to receive(:instance_exec).at_least(:once)
        subject.on_start
      end

      it "calls after stage hooks on finish" do
        expect(task).to receive(:instance_exec).at_least(:once)
        subject.on_finish
      end

      it "calls error hooks on error" do
        error = StandardError.new("Test error")
        expect(task).to receive(:instance_exec).with(error)
        subject.on_error(error)
      end
    end
  end
end 