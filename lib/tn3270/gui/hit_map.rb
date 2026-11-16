# frozen_string_literal: true

module Tn3270
  module Gui
    # The clickable things drawn in one part of a window: each a rectangle
    # (drawing units) and an id saying what it is, such as :caps or
    # [:tab, 2]. A part makes a new map each time it draws itself, so the
    # map always matches what is on the screen.
    class HitMap
      def initialize = @hits = []

      def add(x, y, w, h, id)
        @hits << [x, y, w, h, id]
        self
      end

      # The id of the first thing added that the event's point (:x, :y) is in.
      def at(event)
        px = event[:x]
        py = event[:y]
        found = @hits.find { |x, y, w, h, _| px.between?(x, x + w) && py.between?(y, y + h) }
        found && found[4]
      end

      # Where a thing is: [x, y, w, h], or nil.
      def rect(id) = @hits.find { |hit| hit[4] == id }&.first(4)

      def empty? = @hits.empty?
    end
  end
end
