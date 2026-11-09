# frozen_string_literal: true

require_relative "config"
require_relative "controller"

module Tn3270
  module Gui
    # One session in a window's tab strip: its controller (an engine plus a
    # worker thread) and the view state that belongs to that session. Moving a
    # tab to another window moves this object, so the connection carries on.
    class Tab
      attr_reader :controller
      attr_accessor :selection

      class << self
        # Called (on the worker thread) whenever a tab's session changes, so
        # the window can redraw at once rather than on its next timer tick.
        attr_accessor :on_change
      end

      def initialize(config, controller: nil)
        @config = config
        @dirty = false
        @controller = controller || Controller.new(config, on_change: lambda {
          @dirty = true
          Tab.on_change&.call
        })
        @selection = nil
      end

      # True (once) when the worker has seen a change since the last call.
      def take_dirty
        was = @dirty
        @dirty = false
        was
      end

      # The saved session's name, or nil (a plain host:port, or nothing yet).
      # A plain host:port that matches a saved session takes that session's name.
      def name
        target = @controller.last_target or return nil
        n = target["name"].to_s.strip
        return n unless n.empty?

        saved = Array(@config["connections"]).find do |c|
          c["host"].to_s.strip.casecmp?(target["host"].to_s.strip) && c["port"].to_i == target["port"].to_i
        end
        n = saved && saved["name"].to_s.strip
        n.nil? || n.empty? ? nil : n
      end

      # Tabs open on the same session are numbered: "PROD", "PROD (2)"...
      # (Program#number_tabs). A tab keeps its number while it stays on that
      # session, so the names don't shift when another one closes.
      attr_reader :number, :numbered

      def number_as(name, number)
        @numbered = name
        @number = number
      end

      # Gives each tab whose session changed the lowest number not taken by
      # another tab on the same session. `tabs`: every tab, in every window.
      def self.number_all(tabs)
        tabs.each do |tab|
          # A renamed tab has no number (it gets a fresh one if the name is cleared).
          next tab.number_as(:renamed, nil) if tab.custom_title

          n = tab.name
          next if n == tab.numbered

          used = tabs.select { |o| !o.equal?(tab) && o.numbered == n && o.name == n }.map(&:number)
          tab.number_as(n, n && (1..).find { |i| !used.include?(i) })
        end
      end

      # A name the user gave the tab (Rename Tab), shown instead of the session's.
      attr_reader :custom_title

      def custom_title=(text)
        text = text.to_s.strip
        @custom_title = text.empty? ? nil : text
      end

      # The tab that was showing when this one was opened: the new tab page
      # offers to open the same session again.
      attr_accessor :opened_from

      # What the tab shows: its own name if renamed, else the session name,
      # else host:port, else "New Tab".
      def title
        return @custom_title if @custom_title

        n = name
        return "#{n} (#{@number})" if n && n == @numbered && @number.to_i > 1
        return n if n

        target = @controller.last_target
        target ? Config.display_string(target) : "New Tab"
      end

      def state
        if @controller.connected? then :connected
        elsif @controller.connecting? then :connecting
        else :offline
        end
      end

      # Not connected and not trying to: a session can be opened in it.
      def idle? = state == :offline

      def shutdown = @controller.shutdown
    end

    # Where tabs go in a strip, kept apart from the drawing so it can be tested.
    module TabStrip
      MIN_W = 36.0 # just the status light; the name needs about 60
      MAX_W = 220.0
      NEW_W = 30.0 # the + button after the last tab

      module_function

      # [tab width, left edge of each tab] for `count` tabs between x0 and x1,
      # leaving room for the + button. Tabs shrink to MIN_W; past that the last
      # ones run off the end (and aren't drawn).
      def layout(count, x0, x1)
        return [MAX_W, []] if count.zero?

        width = ((x1 - x0 - NEW_W) / count).clamp(MIN_W, MAX_W)
        [width, Array.new(count) { |i| x0 + (i * width) }]
      end

      # Where tab `from` belongs while it's dragged with its left edge at `x`:
      # the number of other tabs whose middle is to the left of its middle.
      def drop_index(lefts, width, from, x)
        middle = x + (width / 2.0)
        lefts.each_with_index.count { |left, i| i != from && left + (width / 2.0) < middle }
      end

      # Index a tab dropped in from another window takes: the gap nearest `x`.
      def insert_index(lefts, width, x)
        lefts.count { |left| left + (width / 2.0) < x }
      end

      # The list with one item moved from one position to another.
      def move(list, from, to)
        list = list.dup
        item = list.delete_at(from)
        list.insert(to.clamp(0, list.size), item)
      end
    end
  end
end
