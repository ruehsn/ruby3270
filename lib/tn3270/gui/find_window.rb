# frozen_string_literal: true

require_relative "ui"
require_relative "dialogs"

module Tn3270
  module Gui
    # Edit > Find (Ctrl+F). Searches the live screen as you type and
    # highlights every match; Next / Previous move the cursor between them.
    # "Search Screen History" lists matches in saved screens; double-click
    # one to open it in the history window.
    class FindWindow
      include DialogSupport

      MAX_RESULTS = 500

      # app must respond to (privately is fine):
      #   find_on_screen(term, match_case) -> number of matches
      #   find_count                       -> number of matches now
      #   find_step(direction)             -> [current (1-based), total]
      #   find_in_history(term, match_case) -> [[entry_index, time, line], ...]
      #   open_history_at(entry_index)
      #   find_closed
      def initialize(app)
        @app = app
        @results = []
        @open = false
      end

      def open? = @open

      def show
        @win = Ui.window("Find", 560, 460)
        UI.window_on_closing(@win) do
          closed
          1
        end
        main = Ui.vbox
        row = Ui.add(main, Ui.hbox)
        @entry = Ui.add(row, Ui.keep(Ui.entry), stretchy: true)
        UI.entry_on_changed(@entry) { search; nil }
        Ui.add(row, Ui.button("Previous") { step(-1) })
        Ui.add(row, Ui.button("Next") { step(1) })

        row = Ui.add(main, Ui.hbox)
        @match_case = Ui.add(row, Ui.checkbox("Match case") { search })
        @status = Ui.add(row, Ui.label("Type to search the screen."), stretchy: true)

        row = Ui.add(main, Ui.hbox)
        Ui.add(row, Ui.button("Search Screen History") { search_history })
        @history_status = Ui.add(row, Ui.label(""), stretchy: true)

        @table = Ui::Table.new(%w[Screen Time Line]) { |r| open_result(r) }
        Ui.add(main, @table.control, stretchy: true)
        Ui.add(main, Ui.label("Double-click a result to open that screen in the screen history."))
        UI.window_set_child(@win, main)
        @open = true
        show_window(@win)
        Win32.set_column_widths(@table.control, [60, 80, -2])
        Win32.focus_control(@entry)
      end

      def focus = Win32.focus(@win)

      def close
        return unless @open

        closed
        close_window(@win)
      end

      # Called when the live screen changes, to keep the match count current.
      # Leaves "Match 2 of 5" alone while the count is unchanged.
      def refresh
        return unless @open && !term.empty?

        count = @app.send(:find_count)
        search(quiet: true) unless count == @last_count
      end

      private

      def term = Ui.entry_text(@entry)
      def match_case? = Ui.checked?(@match_case)

      def search(quiet: false)
        count = @app.send(:find_on_screen, term, match_case?)
        @last_count = count
        UI.label_set_text(@status, if term.empty? then "Type to search the screen."
                                   elsif count.zero? then "No matches on this screen."
                                   else "#{count} match#{'es' unless count == 1} on this screen."
                                   end)
        UI.label_set_text(@history_status, "") unless quiet
      end

      def step(direction)
        return if term.empty?

        current, total = @app.send(:find_step, direction)
        UI.label_set_text(@status, total.zero? ? "No matches on this screen." : "Match #{current} of #{total} (cursor moved there).")
      end

      def search_history
        return UI.label_set_text(@history_status, "Type something to search for first.") if term.empty?

        @results = @app.send(:find_in_history, term, match_case?).first(MAX_RESULTS)
        @table.rows = @results.map { |index, time, line| [(index + 1).to_s, time.strftime("%H:%M:%S"), line] }
        screens = @results.map(&:first).uniq.size
        UI.label_set_text(@history_status,
                          if @results.empty? then "  Not found in the screen history."
                          else "  #{@results.size} line#{'s' unless @results.size == 1} in #{screens} screen#{'s' unless screens == 1}."
                          end)
      end

      def open_result(row)
        index, = @results[row]
        @app.send(:open_history_at, index) if index
      end

      def closed
        return unless @open

        @open = false
        @app.send(:find_closed)
      end
    end
  end
end
