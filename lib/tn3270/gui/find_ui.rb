# frozen_string_literal: true

require_relative "theme"

module Tn3270
  module Gui
    # Find for a TerminalWindow: the matches on the screen, stepping through
    # them, and searching the screen history. FindWindow is the dialog.
    # Included into TerminalWindow.
    module FindUi
      include Theme

      # Every Find match in yellow; the current one stronger and outlined.
      def draw_find_matches(scr, cw, ch, ox, oy)
        return unless @find

        hits = scr.find(@find[:term], match_case: @find[:match_case])
        @find[:hits] = hits
        hits.each_with_index do |(r, c, len), i|
          current = i == @find[:index]
          x = ox + (c * cw)
          y = oy + (r * ch)
          @painter.fill_rect(x, y, len * cw, ch, FIND_HIT, current ? 0.55 : 0.28)
          @painter.stroke_rect(x, y, len * cw, ch, FIND_HIT, 1.5) if current
        end
      end

      def show_find
        if @find_window&.open?
          @find_window.focus
        else
          @find_window = FindWindow.new(self)
          @find_window.show
        end
      end

      def find_on_screen(term, match_case)
        if term.to_s.empty?
          @find = nil
          redraw
          return 0
        end
        hits = @controller.snapshot&.find(term, match_case: match_case) || []
        @find = { term: term, match_case: match_case, hits: hits, index: nil }
        @history_window&.highlight(term, match_case)
        redraw
        hits.size
      end

      def find_count
        return 0 unless @find

        @controller.snapshot&.find(@find[:term], match_case: @find[:match_case])&.size.to_i
      end

      # Moves to the next / previous match and puts the cursor there.
      def find_step(direction)
        return [0, 0] unless @find

        hits = @controller.snapshot&.find(@find[:term], match_case: @find[:match_case]) || []
        return [0, 0] if hits.empty?

        i = @find[:index]
        i = i.nil? ? (direction.positive? ? 0 : hits.size - 1) : (i + direction) % hits.size
        @find[:index] = i
        row, col, = hits[i]
        @controller.move_to(row, col)
        redraw
        [i + 1, hits.size]
      end

      # [[history_index, time, line_text], ...], oldest screen first.
      def find_in_history(term, match_case)
        @controller.history.each_with_index.flat_map do |entry, i|
          scr = entry.screen
          scr.find(term, match_case: match_case).map(&:first).uniq.map do |row|
            [i, entry.time, scr.row_text(row).strip]
          end
        end
      end

      def open_history_at(index)
        show_history
        @history_window.highlight(@find[:term], @find[:match_case]) if @find
        @history_window.show_entry(index)
      end

      def find_closed
        @find_window = nil
        @find = nil
        @history_window&.highlight(nil, false)
        redraw
      end
    end
  end
end
