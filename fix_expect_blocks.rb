#!/usr/bin/env ruby
# Fix expect blocks that create classes with stages

def fix_class_block(content)
  # Pattern: expect { Class.new do include Minigun::DSL ... stages ... end.new.run }
  lines = content.lines
  result = []
  i = 0

  while i < lines.length
    line = lines[i]

    # Check if we're in an expect block with Class.new
    if line =~ /expect.*do\s*$/ || line =~ /expect\s*\{\s*$/
      # Start collecting the expect block
      expect_indent = line[/^\s*/]
      result << line
      i += 1

      # Look for Class.new do
      while i < lines.length && !(lines[i] =~ /Class\.new.*do\s*$/)
        result << lines[i]
        i += 1
      end

      if i < lines.length && lines[i] =~ /Class\.new.*do\s*$/
        # Found Class.new do
        result << lines[i]
        class_indent = lines[i][/^\s*/]
        i += 1

        # Look for include Minigun::DSL
        while i < lines.length && !(lines[i] =~ /include Minigun::DSL/)
          result << lines[i]
          i += 1
        end

        if i < lines.length && lines[i] =~ /include Minigun::DSL/
          result << lines[i]
          i += 1

          # Skip blank lines and comments
          while i < lines.length && (lines[i] =~ /^\s*$/ || lines[i] =~ /^\s*#/)
            result << lines[i]
            i += 1
          end

          # Check if next line is a stage definition (not pipeline do, not end)
          if i < lines.length &&
             lines[i] =~ /^\s+(producer|processor|consumer|accumulator)/ &&
             !(lines[i] =~ /pipeline do/)
            # Insert pipeline do
            stage_indent = lines[i][/^\s*/]
            result << "#{stage_indent}pipeline do\n"

            # Collect all stage definitions until we hit end.new
            found_end_new = false
            while i < lines.length && !found_end_new
              if lines[i] =~ /^\s*end\.new/
                # Close pipeline do before end.new
                result << "#{stage_indent}end\n"
                found_end_new = true
              end
              result << lines[i]
              i += 1
            end
            next
          end
        end
      end
    end

    result << line
    i += 1
  end

  result.join
end

files = [
  'spec/integration/circular_dependency_spec.rb',
  'spec/integration/from_keyword_spec.rb',
  'spec/integration/mixed_pipeline_stage_routing_spec.rb',
  'spec/integration/multiple_producers_spec.rb',
  'spec/unit/stage_hooks_advanced_spec.rb'
]

files.each do |file|
  next unless File.exist?(file)

  content = File.read(file)
  fixed = fix_class_block(content)

  if fixed != content
    File.write(file, fixed)
    puts "Fixed: #{file}"
  else
    puts "No changes: #{file}"
  end
end

puts "\nDone!"

