#!/usr/bin/env ruby
# Fix mixed pipeline stage routing spec by wrapping stages in pipeline do

file = 'spec/integration/mixed_pipeline_stage_routing_spec.rb'
content = File.read(file)
lines = content.split("\n", -1)

result = []
i = 0

while i < lines.length
  line = lines[i]

  # Find test cases with Class.new
  if line =~ /test_class = Class\.new do/ || line =~ /^\s+Class\.new do/
    result << line
    i += 1

    # Collect until include Minigun::DSL
    while i < lines.length && lines[i] !~ /include Minigun::DSL/
      result << lines[i]
      i += 1
    end

    if i < lines.length && lines[i] =~ /include Minigun::DSL/
      result << lines[i]
      i += 1

      # Skip blank lines, comments, attr_accessor, and initialize
      while i < lines.length && (lines[i] =~ /^\s*$/ || lines[i] =~ /^\s*#/ || lines[i] =~ /^\s+attr_/)
        result << lines[i]
        i += 1
      end

      # Handle initialize
      if i < lines.length && lines[i] =~ /def initialize/
        result << lines[i]
        i += 1
        depth = 1
        while i < lines.length && depth > 0
          depth += 1 if lines[i] =~ /\bdo\b/
          depth -= 1 if lines[i] =~ /\bend\b/
          result << lines[i]
          i += 1
        end

        # Skip blank lines and comments after initialize
        while i < lines.length && (lines[i] =~ /^\s*$/ || lines[i] =~ /^\s*#/)
          result << lines[i]
          i += 1
        end
      end

      # Check if we have stages (not named pipelines)
      if i < lines.length
        next_line = lines[i]
        # Stage definition (producer, processor, consumer) not part of named pipeline
        if next_line =~ /^\s+(producer|processor|consumer|accumulator)\s+:/ &&
           next_line !~ /pipeline\s+:/
          # Collect stages until we hit a named pipeline or end of class
          indent = next_line[/^\s*/]
          stage_lines = []

          while i < lines.length
            # Stop at named pipeline definition
            if lines[i] =~ /^\s+pipeline\s+:/
              break
            end
            # Stop at end of class
            if lines[i] =~ /^\s+end\s*$/ && i + 1 < lines.length && (lines[i+1] =~ /^\s*$/ || lines[i+1] =~ /^\s+instance =/ || lines[i+1] =~ /^\s+end/)
              break
            end
            stage_lines << lines[i]
            i += 1
          end

          # Wrap stages in pipeline do
          if stage_lines.any?
            result << "#{indent}pipeline do"
            result += stage_lines
            result << "#{indent}end"
            result << ""
            next
          end
        end
      end
    end
  end

  result << line
  i += 1
end

File.write(file, result.join("\n"))
puts "Fixed #{file}"

