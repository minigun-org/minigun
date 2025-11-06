# frozen_string_literal: true

module Minigun
  module HUD
    # Represents a stage box in the flow diagram
    # Responsible for rendering itself with appropriate styling
    class DiagramStage
      attr_reader :name, :type, :x, :y, :width, :height

      def initialize(name:, type:, x:, y:, width:, height:)
        @name = name
        @type = type
        @x = x
        @y = y
        @width = width
        @height = height
      end

      # Render the stage box to terminal
      def render(terminal, stage_data, x_offset, y_offset)
        status = determine_status(stage_data)

        # Truncate name to fit in box
        max_name_len = @width - 4 # Leave room for icon and padding
        display_name = if @name.to_s.length > max_name_len
                         "#{@name.to_s[0...(max_name_len - 1)]}…"
                       else
                         @name.to_s
                       end

        # Icon and status indicator
        icon = Theme.stage_icon(@type)
        status_indicator = status_icon(status)

        # Color based on status
        color = case status
                when :active then Theme.stage_active
                when :bottleneck then Theme.stage_bottleneck
                when :error then Theme.stage_error
                when :done then Theme.stage_done
                else Theme.stage_idle
                end

        # Draw top border (use consistent color)
        terminal.write_at(
          x_offset + @x, y_offset + @y,
          "┌#{'─' * (@width - 2)}┐",
          color: color
        )

        # Middle line with content
        content = "#{icon} #{display_name}#{status_indicator}".strip
        padding_left = [(@width - content.length - 2) / 2, 1].max
        padding_right = [@width - content.length - padding_left - 2, 1].max

        terminal.write_at(
          x_offset + @x, y_offset + @y + 1,
          "│#{' ' * padding_left}#{content}#{' ' * padding_right}│",
          color: color
        )

        # Bottom border with optional throughput
        bottom_border = format_bottom_border(stage_data)
        terminal.write_at(x_offset + @x, y_offset + @y + 2, bottom_border, color: color)
      end

      private

      def determine_status(stage_data)
        return :error if stage_data[:items_failed] && stage_data[:items_failed] > 0
        return :bottleneck if stage_data[:is_bottleneck]
        return :active if stage_data[:throughput] && stage_data[:throughput] > 0
        return :done if stage_data[:status] == :finished

        :idle
      end

      def status_icon(status)
        case status
        when :bottleneck then '⚠'
        when :error then '✗'
        else ''
        end
      end

      def format_bottom_border(stage_data)
        throughput = stage_data[:throughput]

        # If there's throughput, embed it in the bottom border
        if throughput && throughput > 0
          # Format throughput compactly
          throughput_str = if throughput >= 1000
                             "#{(throughput / 1000.0).round(1)}K/s"
                           else
                             "#{throughput.round(1)}/s"
                           end

          # Calculate padding to center throughput in bottom border
          content = " #{throughput_str} "
          total_dashes = @width - content.length - 2
          left_dashes = total_dashes / 2
          right_dashes = total_dashes - left_dashes

          "└#{'─' * left_dashes}#{content}#{'─' * right_dashes}┘"
        else
          # Plain bottom border
          "└#{'─' * (@width - 2)}┘"
        end
      end
    end
  end
end
