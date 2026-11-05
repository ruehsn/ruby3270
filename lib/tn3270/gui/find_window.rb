# frozen_string_literal: true

require "glimmer-dsl-libui"
require_relative "dialogs"

module Tn3270
  module Gui
    # Edit > Find (Ctrl+F). Searches the live screen as you type and
    # highlights every match; Next / Previous move the cursor between them.
    # "Search Screen History" lists matches in saved screens; double-click
    # one to open it in the history window.
    class FindWindow
      include Glimmer
      include DialogSupport

      MAX_RESULTS = 500

      # app must respond to:
      #   find_on_screen(term, match_case) -> number of matches
      #   find_step(direction)             -> [current (1-based), total]
      #   find_in_history(term, match_case) -> [[entry_index, time, line], ...]
      #   open_history_at(entry_index)
      #   find_closed
      def initialize(app)
        @app = app
        @rows = []
        @results = []
        @open = false
      end

      def open? = @open

      def show
        f = self
        @win = window("Find", 560, 460, false) {
          margined true
          on_closing do
            f.send(:closed)
            nil
          end
          vertical_box {
            horizontal_box {
              stretchy false
              @entry = entry { on_changed { f.send(:search) } }
              button("Previous") {
                stretchy false
                on_clicked { f.send(:step, -1) }
              }
              button("Next") {
                stretchy false
                on_clicked { f.send(:step, 1) }
              }
            }
            horizontal_box {
              stretchy false
              @match_case = checkbox("Match case") {
                stretchy false
                on_toggled { f.send(:search) }
              }
              @status = label("Type to search the screen.")
            }
            horizontal_box {
              stretchy false
              button("Search Screen History") {
                stretchy false
                on_clicked { f.send(:search_history) }
              }
              @history_status = label("")
            }
            @table = table {
              text_column("Screen")
              text_column("Time")
              text_column("Line")
              cell_rows f.send(:table_rows)
              on_row_double_clicked { |_table, row| f.send(:open_result, row) }
            }
            label("Double-click a result to open that screen in the screen history.") { stretchy false }
          }
        }
        @open = true
        show_window(@win)
        Win32.set_column_widths(@table, [60, 80, -2])
        Win32.focus_control(@entry)
      end

      def focus = Win32.focus(@win)

      # Called when the live screen changes, to keep the match count current.
      # Leaves "Match 2 of 5" alone while the count is unchanged.
      def refresh
        return unless @open && !term.empty?

        count = @app.send(:find_count)
        search(quiet: true) unless count == @last_count
      end

      private

      def table_rows = @rows
      def term = @entry.text.to_s
      def match_case? = @match_case.checked

      def search(quiet: false)
        count = @app.send(:find_on_screen, term, match_case?)
        @last_count = count
        @status.text = if term.empty? then "Type to search the screen."
                       elsif count.zero? then "No matches on this screen."
                       else "#{count} match#{'es' unless count == 1} on this screen."
                       end
        @history_status.text = "" unless quiet
      end

      def step(direction)
        return if term.empty?

        current, total = @app.send(:find_step, direction)
        @status.text = total.zero? ? "No matches on this screen." : "Match #{current} of #{total} (cursor moved there)."
      end

      def search_history
        return @history_status.text = "Type something to search for first." if term.empty?

        @results = @app.send(:find_in_history, term, match_case?).first(MAX_RESULTS)
        @rows.clear
        @results.each do |index, time, line|
          @rows << [(index + 1).to_s, time.strftime("%H:%M:%S"), line]
        end
        screens = @results.map(&:first).uniq.size
        @history_status.text = if @results.empty? then "  Not found in the screen history."
                               else "  #{@results.size} line#{'s' unless @results.size == 1} in #{screens} screen#{'s' unless screens == 1}."
                               end
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
