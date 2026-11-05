# frozen_string_literal: true

require "glimmer-dsl-libui"
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
      include Glimmer
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

      SELECTION = [0x4C, 0x8D, 0xFF].freeze

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
      end

      def open? = @open

      def show
        w = self
        @win = window("Screen History", 1100, 760, false) {
          margined false
          on_closing do
            w.send(:closed)
            nil
          end
          vertical_box {
            padded false
            @area = area {
              on_draw { |params| w.send(:draw, params) }
              on_mouse_down { |event| w.send(:mouse_down, event) }
              on_mouse_drag { |event| w.send(:mouse_drag, event) }
              on_mouse_up { |event| w.send(:mouse_up, event) }
              on_key_down { |event| w.send(:key, event) }
            }
            # A borderless margin around the button row.
            vertical_box {
              stretchy false
              horizontal_box { stretchy false; label("") { stretchy false } }
            }
            horizontal_box {
              stretchy false
              padded true
              label(" ") { stretchy false }
              button("◀  Older") {
                stretchy false
                on_clicked { w.send(:step, -1) }
              }
              button("Newer  ▶") {
                stretchy false
                on_clicked { w.send(:step, 1) }
              }
              @label = label("")
              button("Copy") {
                stretchy false
                on_clicked { w.send(:copy) }
              }
              button("Paste to Session") {
                stretchy false
                on_clicked { w.send(:paste_to_session) }
              }
              button("Close") {
                stretchy false
                on_clicked { w.send(:close) }
              }
              label(" ") { stretchy false }
            }
            horizontal_box { stretchy false; label("") { stretchy false } }
          }
        }
        @open = true
        Win32.set_icon(@win)
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
        @area.queue_redraw_all
      end

      def focus
        Win32.focus(@win) if @open
      end

      # Highlights Find matches in the preview (nil term clears them).
      def highlight(term, match_case)
        @find = term.to_s.empty? ? nil : [term, match_case]
        @area&.queue_redraw_all if @open
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
        @area.queue_redraw_all
      end

      def screen_for(entry)
        @cache[entry.object_id] ||= begin
          @cache.delete(@cache.keys.first) if @cache.size >= CACHE
          entry.screen
        end
      end

      def update_label
        list = entries
        @label.text = if list.empty?
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
          @label.text = "  Select some text on the screen first, then click Paste to Session"
          return
        end
        @on_paste.call(text)
      end

      def select_all
        return unless @current

        scr = screen_for(@current)
        @selection = [0, 0, scr.rows - 1, scr.cols - 1]
        update_label
        @area.queue_redraw_all
      end

      def close
        @win.destroy
        closed
      end

      def closed
        return unless @open

        @open = false
        @on_close.call
      end

      # ---- input ---------------------------------------------------------------

      def key(event)
        mods = Array(event[:modifiers])
        ctrl = mods.include?(:control) || mods.include?(:ctrl)
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
        return unless event[:down] == 1

        @anchor = cell_at(event)
        return unless @anchor || @selection

        @selection = nil
        update_label
        @area.queue_redraw_all
      end

      def mouse_drag(event)
        return unless @anchor && (event[:held].to_i & 1) == 1

        cur = cell_at(event, clamp: true)
        return if @selection.nil? && cur == @anchor

        @selection = [*@anchor, *cur]
        update_label
        @area.queue_redraw_all
      end

      def mouse_up(event)
        return unless event[:up] == 1
        return @anchor = nil if @anchor # end of a selection drag (or a click on the preview)

        hit = @hits.find { |x, y, w, h, _| event[:x].between?(x, x + w) && event[:y].between?(y, y + h) }
        return unless hit

        action = hit[4]
        action.is_a?(Integer) ? go(action) : step(action == :older ? -1 : 1)
      end

      # ---- drawing -------------------------------------------------------------

      def draw(params)
        w = params[:area_width]
        h = params[:area_height]
        @hits = []
        @grid = nil
        rectangle(0, 0, w, h) { fill rgb(BACKGROUND) }
        list = entries
        if list.empty?
          message(w, h, "No screens saved yet.\nA screen is saved each time you press Enter, a PF or PA key, or Clear.")
          return
        end

        i = current_index
        scr = screen_for(list[i])
        preview_h = [h - STRIP_H - 16, 80].max
        font = @config["font"]
        size, cw, ch, ox, oy = fit_grid(scr.rows, scr.cols, 16, 12, w - 32, preview_h - 12, font)
        rectangle(ox - 6, oy - 6, (cw * scr.cols) + 12, (ch * scr.rows) + 12) { stroke rgb(FRAME); fill rgb(BACKGROUND) }
        paint_cells(scr, size, cw, ch, ox, oy, font, underline: @config["underline_input_fields"])
        @grid = [cw, ch, ox, oy, scr.rows, scr.cols]
        if @find
          scr.find(@find[0], match_case: @find[1]).each do |r, c, len|
            rectangle(ox + (c * cw), oy + (r * ch), len * cw, ch) { fill rgb([0xFF, 0xD2, 0x3F], 0.35) }
          end
        end
        if @selection
          r1, r2 = [@selection[0], @selection[2]].minmax
          c1, c2 = [@selection[1], @selection[3]].minmax
          rectangle(ox + (c1 * cw), oy + (r1 * ch), (c2 - c1 + 1) * cw, (r2 - r1 + 1) * ch) { fill rgb(SELECTION, 0.35) }
        end
        draw_strip(list, i, scr, w, h)
      end

      def message(w, h, text)
        text(40, (h / 2.0) - 30, w - 80) {
          align :center
          default_font family: @config["font"], size: 13
          string(text) { color rgb(MUTED) }
        }
      end

      def draw_strip(list, current, scr, w, h)
        top = h - STRIP_H
        rectangle(0, top, w, STRIP_H) { fill rgb(PANEL) }
        rectangle(0, top, w, 1) { fill rgb(FRAME) }

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
          rectangle(x - 3, y - 3, thumb_w + 6, thumb_h + 6) { fill rgb(selected ? ACCENT : FRAME, selected ? 1.0 : 0.6) }
          rectangle(x, y, thumb_w, thumb_h) { fill rgb(BACKGROUND) }
          paint_minimap(screen_for(list[idx]), x + 4, y + 4, thumb_w - 8, thumb_h - 8)
          caption = "#{idx + 1}  ·  #{list[idx].time.strftime('%H:%M:%S')}"
          text(x, y + thumb_h + 7, thumb_w) {
            align :center
            default_font family: @config["font"], size: 8.5
            string(caption) { color rgb(selected ? [0xFF, 0xFF, 0xFF] : MUTED) }
          }
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
        circle(cx, cy, r) { fill rgb(FRAME, enabled ? 0.9 : 0.3) }
        k = r * 0.38
        pts = if dir == :left
                [cx + (k * 0.5), cy - k, cx - (k * 0.7), cy, cx + (k * 0.5), cy + k]
              else
                [cx - (k * 0.5), cy - k, cx + (k * 0.7), cy, cx - (k * 0.5), cy + k]
              end
        pen = rgb(enabled ? [0xFF, 0xFF, 0xFF] : MUTED, enabled ? 1.0 : 0.4).merge(thickness: 2.5, cap: :round, join: :round)
        polyline(*pts) { stroke pen }
        @hits << [cx - r, cy - r, r * 2, r * 2, dir == :left ? :older : :newer] if enabled
      end
    end
  end
end
