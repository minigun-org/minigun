#!/usr/bin/env ruby
# Quick script to wrap stage definitions in pipeline do blocks

files_to_fix = [
  'spec/integration/circular_dependency_spec.rb',
  'spec/integration/from_keyword_spec.rb',
  'spec/integration/isolated_pipelines_spec.rb',
  'spec/integration/mixed_pipeline_stage_routing_spec.rb',
  'spec/integration/multiple_producers_spec.rb',
  'spec/unit/stage_hooks_advanced_spec.rb'
]

files_to_fix.each do |file|
  next unless File.exist?(file)

  content = File.read(file)
  lines = content.lines

  # Find all Class.new blocks with include Minigun::DSL
  modified = false
  in_class_block = false
  class_start = nil
  brace_count = 0

  i = 0
  while i < lines.length
    line = lines[i]

    # Detect Class.new do
    if line =~ /Class\.new.*do\s*$/
      in_class_block = true
      brace_count = 1
      class_start = i
    elsif in_class_block
      # Track do/end balance
      brace_count += line.scan(/\bdo\b/).count
      brace_count -= line.scan(/\bend\b/).count

      if brace_count == 0
        in_class_block = false
        class_start = nil
      end

      # If we find include Minigun::DSL and the next non-blank/non-comment line
      # is a stage definition, add pipeline do
      if line =~ /include Minigun::DSL/ && !modified
        # Find next significant line
        j = i + 1
        while j < lines.length && (lines[j] =~ /^\s*$/ || lines[j] =~ /^\s*#/ || lines[j] =~ /^\s*def initialize/ || lines[j] =~ /^\s*attr_/)
          j += 1
          # Skip initialize block
          if lines[j-1] =~ /def initialize/
            indent_count = 1
            while j < lines.length && indent_count > 0
              indent_count += lines[j].scan(/\bdo\b/).count
              indent_count -= lines[j].scan(/\bend\b/).count
              j += 1
            end
          end
        end

        # Check if next line is a stage definition
        if j < lines.length && lines[j] =~ /^\s+(producer|processor|consumer|accumulator|spawn_|before|after|reroute_|pipeline :|max_)/
          # Check if not already in pipeline do
          unless lines[i..j].any? { |l| l =~ /^\s+pipeline do/ }
            # Add pipeline do
            indent = lines[j][/^\s*/]
            lines.insert(j, "#{indent}pipeline do\n")

            # Find the end of this class block and add end before it
            k = j + 1
            class_brace_count = 1
            while k < lines.length && class_brace_count > 0
              class_brace_count += lines[k].scan(/\bdo\b/).count
              class_brace_count -= lines[k].scan(/\bend\b/).count
              if class_brace_count == 1 && lines[k] =~ /^\s+end\s*$/
                # This is the class end, insert before it
                lines.insert(k, "#{indent}end\n")
                break
              end
              k += 1
            end

            modified = true
            break
          end
        end
      end
    end

    i += 1
  end

  if modified
    File.write(file, lines.join)
    puts "Fixed: #{file}"
  else
    puts "Skipped: #{file} (already fixed or no changes needed)"
  end
end

puts "\nDone!"

