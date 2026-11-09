# frozen_string_literal: true

require_relative "ui"
require_relative "screen_painter"
require_relative "clipboard"
require_relative "dialogs"
require_relative "win32"

module Tn3270
  module Gui
    # The screen history window: a large preview of one saved screen, and a
    # strip of thumbnails below it with arrows to move through them.
    # Drag on the preview to select a block of text.
    #   Left / Right   older / newer      Home / End   oldest / newest
    #   Ctrl+C         copy selection (or whole screen)
    #   Ctrl+A         select all         Escape       close
    # "Paste to Session" types the selection into the live screen.
    class HistoryWindow
      include DialogSupport
      include ScreenPainter

      STRIP_H = 150
      ARROW_W = 44
      GAP = 12
      CACHE = 24
      PANEL = [0x07, 0x0A, 0x0D].freeze
      FRAME = [0x2A, 0x33, 0x40].freeze
      ACCENT = [0x4C, 0x8D, 0xFF].freeze
      MUTED = [0x8A, 0x96, 0xA8].freeze
      WHITE = [0xFF, 0xFF, 0xFF].freeze
      SELECTION = [0x4C, 0x8D, 0xFF].freeze
      FIND_HIT = [0xFF, 0xD2, 0x3F].freeze

      # on_paste is called with text to type into the live session.
      def initialize(controller, config, on_close:, on_paste:)
        @controller = controller
        @config = config
        @on_close = on_close
        @on_paste = on_paste
        @current = entries.last
        @cache = {}
        @hits = []
        @open = false
        @grid = nil      # where the preview was last drawn: [cw, ch, ox, oy, rows, cols]
        @selection = nil # [row1, col1, row2, col2] on the previewed screen
        @anchor = nil
        @painter = Painter.new
      end

      def open? = @open

      def show
        @win = Ui.window("Screen History", 1100, 760, margined: false)
        UI.window_on_closing(@win) do
          closed
          1
        end
        main = Ui.vbox(padded: false)
        @area = Ui::Area.new(draw: ->(p) { draw(p) }, mouse: ->(e) { mouse(e) }, key: ->(e) { key(e) })
        Ui.add(main, @area.control, stretchy: true)
        row = Ui.add(main, Ui.hbox)
        Ui.add(row, Ui.label(" "))
        Ui.add(row, Ui.button("◀  Older") { step(-1) })
        Ui.add(row, Ui.button("Newer  ▶") { step(1) })
        @label = Ui.add(row, Ui.label(""), stretchy: true)
        Ui.add(row, Ui.button("Copy") { copy })
        Ui.add(row, Ui.button("Paste to Session") { paste_to_session })
        Ui.add(row, Ui.button("Close") { close })
        Ui.add(row, Ui.label(" "))
        UI.window_set_child(@win, main)
        @open = true
        update_label
        show_window(@win)
      end

      # Called when the controller saves a new screen.
      def refresh
        return unless @open

        list = entries
        if @current.nil? || @following || index_of(@current).nil?
          @selection = nil unless @current.equal?(list.last)
          @current = list.last
        end
        update_label
        @area.redraw
      end

      def focus
        Win32.focus(@win) if @open
      end

      # The main window switched tabs: show that session's history.
      def controller=(controller)
        return if controller.equal?(@controller)

        @controller = controller
        @current = nil
        @selection = nil
        @cache = {}
        refresh
      end

      # Highlights Find matches in the preview (nil term clears them).
      def highlight(term, match_case)
        @find = term.to_s.empty? ? nil : [term, match_case]
        @area&.redraw if @open
      end

      # Shows a particular saved screen (0 = oldest).
      def show_entry(index)
        go(index)
        focus
      end

      private

      def entries = @controller.history

      def index_of(entry)
        entry && entries.index { |e| e.equal?(entry) }
      end

      def current_index = index_of(@current) || (entries.size - 1)

      def step(delta) = go(current_index + delta)

      def go(index)
        list = entries
        return if list.empty?

        index = index.clamp(0, list.size - 1)
        @selection = nil unless list[index].equal?(@current)
        @current = list[index]
        @following = index == list.size - 1
        update_label
        @area.redraw
      end

      def screen_for(entry)
        @cache[entry.object_id] ||= begin
          @cache.delete(@cache.keys.first) if @cache.size >= CACHE
          entry.screen
        end
      end

      def update_label
        list = entries
        text = if list.empty?
                 "  No screens saved yet"
               else
                 i = current_index
                 e = list[i]
                 host = e.status&.host
                 hint = if @selection
                          r1, c1, r2, c2 = @selection
                          "   Selected #{(r2 - r1).abs + 1} x #{(c2 - c1).abs + 1}"
                        else
                          "   Drag on the screen to select text"
                        end
                 "  Screen #{i + 1} of #{list.size}   #{stamp(e.time)}#{host ? "   #{host}" : ''}#{hint}"
               end
        UI.label_set_text(@label, text)
      end

      # The selected text, or nil when nothing is selected.
      def selected_text
        return nil unless @current && @selection

        screen_for(@current).region_text(*@selection)
      end

      def stamp(time)
        same_day = time.strftime("%F") == Time.now.strftime("%F")
        same_day ? time.strftime("%H:%M:%S") : time.strftime("%b %-d %H:%M:%S")
      end

      # Copies the selection, or the whole screen when nothing is selected.
      def copy
        return unless @current

        Clipboard.copy(selected_text || screen_for(@current).text)
      end

      # Types the selection into the live session at its cursor. Lines after
      # the first go to the following input fields, like a normal paste.
      def paste_to_session
        # Blank rows at the edges of the selection would just skip fields.
        text = selected_text&.gsub(/\A(\s*\n)+|(\n\s*)+\z/, "")
        if text.nil? || text.strip.empty?
          UI.label_set_text(@label, "  Select some text on the screen first, then click Paste to Session")
          return
        end
        @on_paste.call(text)
      end

      def select_all
        return unless @current

        scr = screen_for(@current)
        @selection = [0, 0, scr.rows - 1, scr.cols - 1]
        update_label
        @area.redraw
      end

      def close
        closed
        close_window(@win)
      end
      public :close # the main window closes it when it goes

      def closed
        return unless @open

        @open = false
        @on_close.call
      end

      # ---- input ---------------------------------------------------------------

      def key(event)
        return false if event[:up]

        ctrl = event[:modifiers].include?(:control)
        case event[:ext_key]
        when :left, :up, :page_up then step(-1)
        when :right, :down, :page_down then step(1)
        when :home then go(0)
        when :end then go(entries.size - 1)
        when :escape then close
        else
          key = event[:key].to_s
          if ctrl && key.casecmp?("c") then copy
          elsif ctrl && key.casecmp?("a") then select_all
          elsif event[:key_value] == 27 then close
          else return false
          end
        end
        true
      end

      def mouse(event)
        if event[:down] == 1 then mouse_down(event)
        elsif event[:up] == 1 then mouse_up(event)
        elsif event[:held].to_i.anybits?(1) then mouse_drag(event)
        end
      end

      # Screen cell under the mouse in the preview, or nil outside it.
      def cell_at(event, clamp: false)
        return nil unless @grid

        cw, ch, ox, oy, rows, cols = @grid
        col = ((event[:x] - ox) / cw).floor
        row = ((event[:y] - oy) / ch).floor
        return [row.clamp(0, rows - 1), col.clamp(0, cols - 1)] if clamp
        return nil unless row.between?(0, rows - 1) && col.between?(0, cols - 1)

        [row, col]
      end

      def mouse_down(event)
        @anchor = cell_at(event)
        return unless @anchor || @selection

        @selection = nil
        update_label
        @area.redraw
      end

      def mouse_drag(event)
        return unless @anchor

        cur = cell_at(event, clamp: true)
        return if @selection.nil? && cur == @anchor

        @selection = [*@anchor, *cur]
        update_label
        @area.redraw
      end

      def mouse_up(event)
        return @anchor = nil if @anchor # end of a selection drag (or a click on the preview)

        hit = @hits.find { |x, y, w, h, _| event[:x].between?(x, x + w) && event[:y].between?(y, y + h) }
        return unless hit

        action = hit[4]
        action.is_a?(Integer) ? go(action) : step(action == :older ? -1 : 1)
      end

      # ---- drawing -------------------------------------------------------------

      def draw(params)
        pt = @painter
        pt.context = params[:context]
        w = params[:area_width]
        h = params[:area_height]
        @hits = []
        @grid = nil
        pt.fill_rect(0, 0, w, h, BACKGROUND)
        list = entries
        if list.empty?
          pt.text(40, (h / 2.0) - 30, w - 80, "No screens saved yet.\nA screen is saved each time you press Enter, a PF or PA key, or Clear.",
                  MUTED, @config["font"], 13, align: :center)
          return
        end

        i = current_index
        scr = screen_for(list[i])
        preview_h = [h - STRIP_H - 16, 80].max
        font = @config["font"]
        size, cw, ch, ox, oy = fit_grid(scr.rows, scr.cols, 16, 12, w - 32, preview_h - 12, font)
        pt.fill_rect(ox - 6, oy - 6, (cw * scr.cols) + 12, (ch * scr.rows) + 12, BACKGROUND)
        pt.stroke_rect(ox - 6, oy - 6, (cw * scr.cols) + 12, (ch * scr.rows) + 12, FRAME)
        paint_cells(pt, scr, size, cw, ch, ox, oy, font, underline: @config["underline_input_fields"])
        @grid = [cw, ch, ox, oy, scr.rows, scr.cols]
        if @find
          scr.find(@find[0], match_case: @find[1]).each do |r, c, len|
            pt.fill_rect(ox + (c * cw), oy + (r * ch), len * cw, ch, FIND_HIT, 0.35)
          end
        end
        if @selection
          r1, r2 = [@selection[0], @selection[2]].minmax
          c1, c2 = [@selection[1], @selection[3]].minmax
          pt.fill_rect(ox + (c1 * cw), oy + (r1 * ch), (c2 - c1 + 1) * cw, (r2 - r1 + 1) * ch, SELECTION, 0.35)
        end
        draw_strip(list, i, scr, w, h)
      end

      def draw_strip(list, current, scr, w, h)
        pt = @painter
        top = h - STRIP_H
        pt.fill_rect(0, top, w, STRIP_H, PANEL)
        pt.fill_rect(0, top, w, 1, FRAME)

        thumb_h = STRIP_H - 46
        fm = FontMetrics.for(@config["font"])
        thumb_w = thumb_h * (scr.cols * fm[:advance]) / (scr.rows * fm[:line])
        usable = w - (2 * ARROW_W)
        count = [((usable + GAP) / (thumb_w + GAP)).floor, 1].max
        count -= 1 if count.even? && count > 1
        half = count / 2
        row_w = (count * thumb_w) + ((count - 1) * GAP)
        x0 = ARROW_W + ((usable - row_w) / 2.0)
        y = top + 14

        count.times do |slot|
          idx = current - half + slot
          next if idx.negative? || idx >= list.size

          x = x0 + (slot * (thumb_w + GAP))
          selected = idx == current
          pt.fill_rect(x - 3, y - 3, thumb_w + 6, thumb_h + 6, selected ? ACCENT : FRAME, selected ? 1.0 : 0.6)
          pt.fill_rect(x, y, thumb_w, thumb_h, BACKGROUND)
          paint_minimap(pt, screen_for(list[idx]), x + 4, y + 4, thumb_w - 8, thumb_h - 8)
          caption = "#{idx + 1}  ·  #{list[idx].time.strftime('%H:%M:%S')}"
          pt.text(x, y + thumb_h + 7, thumb_w, caption, selected ? WHITE : MUTED, @config["font"], 8.5, align: :center)
          @hits << [x - 3, y - 3, thumb_w + 6, thumb_h + 30, idx]
        end

        arrow(6, top, ARROW_W - 12, STRIP_H, :left, current.positive?)
        arrow(w - ARROW_W + 6, top, ARROW_W - 12, STRIP_H, :right, current < list.size - 1)
      end

      # A chevron button at either end of the strip.
      def arrow(x, top, width, height, dir, enabled)
        cy = top + (height / 2.0) - 8
        r = width / 2.0
        cx = x + r
        @painter.fill_circle(cx, cy, r, FRAME, enabled ? 0.9 : 0.3)
        k = r * 0.38
        pts = if dir == :left
                [cx + (k * 0.5), cy - k, cx - (k * 0.7), cy, cx + (k * 0.5), cy + k]
              else
                [cx - (k * 0.5), cy - k, cx + (k * 0.7), cy, cx - (k * 0.5), cy + k]
              end
        @painter.polyline(pts, enabled ? WHITE : MUTED, 2.5, enabled ? 1.0 : 0.4, cap: :round)
        @hits << [cx - r, cy - r, r * 2, r * 2, dir == :left ? :older : :newer] if enabled
      end
    end
  end
end
