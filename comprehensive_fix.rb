#!/usr/bin/env ruby
# Comprehensive fix for all remaining specs

require 'stringio'

def wrap_stages_in_pipeline_do(content)
  lines = content.split("\n", -1)  # Keep empty lines
  result = []
  i = 0

  while i < lines.length
    line = lines[i]

    # Find Class.new do blocks
    if line =~ /Class\.new\s+do\s*$/
      result << line
      i += 1
      class_indent = line[/^\s*/]

      # Find include Minigun::DSL
      while i < lines.length && lines[i] !~ /include Minigun::DSL/
        result << lines[i]
        i += 1
      end

      if i < lines.length && lines[i] =~ /include Minigun::DSL/
        result << lines[i]
        i += 1

        # Skip blank lines, comments, attr_, def initialize
        in_initialize = false
        while i < lines.length
          if lines[i] =~ /def initialize/
            result << lines[i]
            i += 1
            in_initialize = true
            # Collect until matching end
            depth = 1
            while i < lines.length && depth > 0
              depth += 1 if lines[i] =~ /\bdo\b/
              depth -= 1 if lines[i] =~ /\bend\b/
              result << lines[i]
              i += 1
            end
            in_initialize = false
          elsif lines[i] =~ /^\s*$/ || lines[i] =~ /^\s*#/ || lines[i] =~ /^\s+attr_/
            result << lines[i]
            i += 1
          else
            break  # Found something significant
          end
        end

        # Check if next line is a stage definition or hook (not pipeline :name)
        if i < lines.length &&
           lines[i] =~ /^\s+(producer|processor|consumer|accumulator|spawn_|before|after|before_run|after_run|before_fork|after_fork)/ &&
           lines[i] !~ /pipeline\s+:/
          # Insert pipeline do
          stage_indent = lines[i][/^\s*/]
          result << "#{stage_indent}pipeline do"

          # Collect until we hit "end" that closes the Class.new
          depth = 0
          found_class_end = false
          while i < lines.length && !found_class_end
            # Check if this is the closing end for Class.new
            if lines[i] =~ /^\s*end\.new/ || (lines[i] =~ /^\s+end\s*$/ && depth == 0 && lines[i+1] && (lines[i+1] =~ /^(\s*)end/ || lines[i+1] =~ /\.new/))
              # This is the class end
              result << "#{stage_indent}end"
              found_class_end = true
            end

            # Track depth for nested blocks
            depth += 1 if lines[i] =~ /\bdo\b/
            depth -= 1 if lines[i] =~ /\bend\b/

            result << lines[i]
            i += 1
          end
          next
        end
      end
    end

    result << line
    i += 1
  end

  result.join("\n")
end

# List of files to fix
files = [
  'spec/integration/from_keyword_spec.rb',
  'spec/integration/mixed_pipeline_stage_routing_spec.rb',
  'spec/integration/multiple_producers_spec.rb',
  'spec/unit/stage_hooks_advanced_spec.rb'
]

files.each do |file|
  next unless File.exist?(file)

  content = File.read(file)
  fixed = wrap_stages_in_pipeline_do(content)

  if fixed != content
    File.write(file, fixed)
    puts "Fixed: #{file}"
  else
    puts "No changes: #{file}"
  end
end

puts "\nDone!"

