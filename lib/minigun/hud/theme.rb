# frozen_string_literal: true

module Minigun
  module HUD
    # Cyberpunk-inspired color theme (Matrix/Blade Runner/Hackers)
    module Theme
      # Color palette
      def self.primary
        Terminal::COLORS[:green]
      end

      def self.secondary
        Terminal::COLORS[:cyan]
      end

      def self.accent
        Terminal::COLORS[:magenta]
      end

      def self.warning
        Terminal::COLORS[:yellow]
      end

      def self.danger
        Terminal::COLORS[:red]
      end

      def self.success
        Terminal::COLORS[:green_bright]
      end

      def self.info
        Terminal::COLORS[:blue]
      end

      def self.muted
        Terminal::COLORS[:gray]
      end

      def self.text
        Terminal::COLORS[:white]
      end

      # Stage status colors
      def self.stage_active
        Terminal::COLORS[:green_bright] + Terminal::COLORS[:bold]
      end

      def self.stage_idle
        Terminal::COLORS[:gray]
      end

      def self.stage_bottleneck
        Terminal::COLORS[:yellow] + Terminal::COLORS[:bold]
      end

      def self.stage_error
        Terminal::COLORS[:red] + Terminal::COLORS[:bold]
      end

      def self.stage_done
        Terminal::COLORS[:gray]
      end

      # Performance indicators
      def self.throughput_high
        Terminal::COLORS[:green_bright]
      end

      def self.throughput_medium
        Terminal::COLORS[:yellow]
      end

      def self.throughput_low
        Terminal::COLORS[:orange]
      end

      def self.throughput_critical
        Terminal::COLORS[:red]
      end

      # Box borders
      def self.border
        Terminal::COLORS[:cyan_dim]
      end

      def self.border_active
        Terminal::COLORS[:cyan]
      end

      # Subtle flow animation colors (dim → medium → dim)
      def self.flow_dim
        Terminal::COLORS[:cyan_dim]
      end

      def self.flow_medium
        Terminal::COLORS[:cyan]
      end

      # Draining animation color (darker, showing flow winding down)
      def self.drain_dim
        Terminal::COLORS[:gray]
      end

      # Character mappings: thin → thick for animation
      CHAR_PAIRS = {
        vertical: ['│', '┃'],
        horizontal: ['─', '━'],
        corner_tl: ['┌', '┏'],
        corner_tr: ['┐', '┓'],
        corner_bl: ['└', '┗'],
        corner_br: ['┘', '┛'],
        t_down: ['┬', '┳'],
        t_up: ['┴', '┻'],
        t_right: ['├', '┣'],
        t_left: ['┤', '┫'],
        cross: ['┼', '╋']
      }.freeze

      # Generate flowing animation frames: 6 dim thin, 1 medium thick, 1 medium thin
      FLOW_ANIMATION = CHAR_PAIRS.transform_values do |thin, thick|
        [
          *Array.new(6) { [thin, :flow_dim] },
          [thick, :flow_medium],
          [thin, :flow_medium]
        ]
      end.freeze

      # Draining state (static, no animation - just gray thin chars)
      DRAIN_ANIMATION = CHAR_PAIRS.transform_values { |thin, _| [[thin, :drain_dim]] }.freeze

      # Get animated character and color for a given char type and distance
      # @param char_type [Symbol] Type of character (:vertical, :horizontal, :corner_tl, etc.)
      # @param distance [Integer] Distance from source (for phase calculation)
      # @param animation_frame [Integer] Global animation frame counter
      # @param active [Boolean] Whether the connection is active
      # @param drain_distance [Integer, nil] How far the drain has progressed from source (nil if not draining)
      # @return [Array<String, String>] [character, color_code]
      def self.animated_flow_char(char_type, distance, animation_frame, active, drain_distance: nil)
        # Check if this cell has been drained (wave reached it)
        drained = !drain_distance.nil? && distance <= drain_distance

        # Check if drain is in progress but wave hasn't reached this cell yet
        draining = !drain_distance.nil? && distance > drain_distance

        # Determine which animation to use:
        # - If drained: gray static (drained)
        # - If active OR draining: cyan animated (flowing/draining)
        # - Otherwise: gray static (idle/not started)
        frames = if drained
                   DRAIN_ANIMATION[char_type]
                 elsif active || draining
                   FLOW_ANIMATION[char_type]
                 else
                   DRAIN_ANIMATION[char_type] # Gray for idle state
                 end

        return [static_char_for_type(char_type), muted] unless frames

        # Calculate phase based on distance from source and global animation frame
        # Subtracting distance makes the animation flow from source to target
        phase = (animation_frame - distance) % frames.length
        char, color_method = frames[phase]

        [char, send(color_method)]
      end

      # Get static (non-animated) character for a given type
      def self.static_char_for_type(char_type)
        CHAR_PAIRS.dig(char_type, 0) || '│'
      end

      # Stage type icons
      def self.stage_icon(stage_type)
        case stage_type
        when :producer
          '▶'
        when :processor
          '◆'
        when :consumer
          '◀'
        when :accumulator
          '⊞'
        when :router
          '◇'
        when :fork
          '⑂'
        else
          '●'
        end
      end

      # Status indicators
      def self.status_indicator(status)
        case status
        when :active
          '⚡'
        when :idle
          '⏸'
        when :bottleneck
          '⚠'
        when :error
          '✖'
        when :done
          '✓'
        else
          '●'
        end
      end

      # Format numbers with colors based on magnitude
      def self.format_throughput(value)
        color = if value > 1000
                  throughput_high
                elsif value > 100
                  throughput_medium
                elsif value > 10
                  throughput_low
                else
                  throughput_critical
                end

        formatted = if value > 1_000_000
                      "#{(value / 1_000_000.0).round(2)}M"
                    elsif value > 1000
                      "#{(value / 1000.0).round(2)}K"
                    else
                      value.round(2).to_s
                    end

        "#{color}#{formatted}#{Terminal::COLORS[:reset]}"
      end

      # Format latency with color
      def self.format_latency(ms)
        color = if ms < 10
                  success
                elsif ms < 100
                  throughput_medium
                elsif ms < 1000
                  warning
                else
                  danger
                end

        "#{color}#{ms.round(1)}ms#{Terminal::COLORS[:reset]}"
      end

      # Format percentages
      def self.format_percentage(value)
        color = if value > 90
                  success
                elsif value > 70
                  throughput_medium
                elsif value > 50
                  warning
                else
                  danger
                end

        "#{color}#{value.round(1)}%#{Terminal::COLORS[:reset]}"
      end

      # Cyberpunk banner/logo
      def self.logo
        [
          '███╗   ███╗██╗███╗   ██╗██╗ ██████╗ ██╗   ██╗███╗   ██╗',
          '████╗ ████║██║████╗  ██║██║██╔════╝ ██║   ██║████╗  ██║',
          '██╔████╔██║██║██╔██╗ ██║██║██║  ███╗██║   ██║██╔██╗ ██║',
          '██║╚██╔╝██║██║██║╚██╗██║██║██║   ██║██║   ██║██║╚██╗██║',
          '██║ ╚═╝ ██║██║██║ ╚████║██║╚██████╔╝╚██████╔╝██║ ╚████║',
          '╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝',
          '                    GO BRRRRR 🔥                       '
        ]
      end
    end
  end
end
