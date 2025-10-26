# frozen_string_literal: true

module Minigun
  # Simple emissions collector
  class Emissions
    def initialize
      @items = []
    end

    def emit(item)
      @items << item
    end

    def emit_to_stage(target, item)
      @items << { item: item, target: target }
    end

    def items
      @items
    end

    def clear
      @items.clear
    end

    def empty?
      @items.empty?
    end

    def size
      @items.size
    end
  end
end

