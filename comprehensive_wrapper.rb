#!/usr/bin/env ruby
# Comprehensive wrapper for all remaining test files

require 'fileutils'

def wrap_stages_before_named_pipelines(content)
  lines = content.split("\n", -1)
  result = []
  i = 0

  while i < lines.length
    line = lines[i]

    # Find Class.new do ... include Minigun::DSL
    if line =~ /Class\.new\s+do\s*$/
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

        # Collect attr_, initialize, etc.
        start_of_stages = i
        while i < lines.length && (lines[i] =~ /^\s*$/ || lines[i] =~ /^\s*#/ || lines[i] =~ /^\s+attr_/)
          result << lines[i]
          i += 1
        end

        # Handle def initialize
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

          # Skip blank/comment lines
          while i < lines.length && (lines[i] =~ /^\s*$/ || lines[i] =~ /^\s*#/)
            result << lines[i]
            i += 1
          end
        end

        # Check if we have stage definitions before a named pipeline
        if i < lines.length
          next_line = lines[i]
          # Stage definition (not inside pipeline do)
          if next_line =~ /^\s+(producer|processor|consumer|accumulator|spawn_|before\s|after\s)/ &&
             next_line !~ /pipeline\s+:/
            # Need to collect stages until we hit pipeline :name
            indent = next_line[/^\s*/]
            stage_lines = []

            # Collect stages
            while i < lines.length
              break if lines[i] =~ /^\s+pipeline\s+:/  # Named pipeline starts
              break if lines[i] =~ /^\s+end\s*$/ && lines[i+1] && lines[i+1] =~ /^\s*end/  # Class end
              stage_lines << lines[i]
              i += 1
            end

            # Wrap if we found stages
            if stage_lines.any?
              result << "#{indent}pipeline do"
              result += stage_lines
              result << "#{indent}end"
              result << ""  # Blank line after
            end

            next  # Continue with rest of file
          end
        end
      end
    end

    result << line
    i += 1
  end

  result.join("\n")
end

files = [
  'spec/integration/mixed_pipeline_stage_routing_spec.rb',
  'spec/integration/multiple_producers_spec.rb',
  'spec/unit/stage_hooks_advanced_spec.rb'
]

files.each do |file|
  next unless File.exist?(file)

  content = File.read(file)
  fixed = wrap_stages_before_named_pipelines(content)

  if fixed != content
    File.write(file, fixed)
    puts "Fixed: #{file}"
  else
    puts "No changes: #{file}"
  end
end

puts "\nDone!"

