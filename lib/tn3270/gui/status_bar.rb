# frozen_string_literal: true

require_relative "theme"

module Tn3270
  module Gui
    # The status bar across the bottom of a TerminalWindow, and the tooltips
    # of its buttons. libui has no tooltips for a drawing area, so they are
    # drawn here: after the pointer rests on a button for TIP_DELAY seconds.
    # Included into TerminalWindow.
    module StatusBar
      include Theme

      # The status bar, pinned across the bottom of the window: [menu]
      # [connection] host, keyboard state, insert mode, messages, and screen
      # size / cursor position on the right. Its size doesn't change with the
      # screen font size.
      def draw_status(scr, w, h, font)
        pt = @painter
        y = h - STATUS_H
        pt.fill_rect(0, y, w, STATUS_H, STATUS_BG)
        tint = TAB_COLORS[@tab&.color] # the session's color runs along the top of the bar
        tint ? pt.fill_rect(0, y, w, 2, tint) : pt.fill_rect(0, y, w, 1, [0x2A, 0x33, 0x40])
        fm = FontMetrics.for(font)
        size = STATUS_FONT_SIZE
        cw = fm[:advance] * size
        text_y = y + ((STATUS_H - (fm[:line] * size)) / 2.0)
        icon_h = STATUS_H * 0.8
        icon_y = y + ((STATUS_H - icon_h) / 2.0)
        btn = STATUS_H * 1.2
        @status_hits = HitMap.new
        x = 6

        if compact_menu?
          draw_menu_icon(x, icon_y, btn, icon_h)
          @status_hits.add(x, y, btn, STATUS_H, :menu)
          x += btn
        end
        draw_connection_icon(x, icon_y, btn, icon_h)
        @status_hits.add(x, y, btn, STATUS_H, :connection)
        x += btn + (cw * 0.5)

        st = scr&.status
        connected = st&.connected?
        left = if connected then host_timing
               elsif @controller.connecting? then "Connecting..."
               else "Disconnected - click the dot to connect"
               end
        unlock_key = Keymap.keys_for(bindings, "escape").first || Keymap.keys_for(bindings, "reset").first
        lock = if !connected then ""
               elsif st.error? || @controller.operator_error? then "X -f#{" (#{unlock_key} resets)" if unlock_key}"
               elsif st.keyboard_locked? || @controller.waiting_for_host? then "X SYSTEM"
               else ""
               end
        sel = @selection ? "SELECTED - #{keys_label('copy')} to copy" : ""
        ahead = @controller.typeahead_count
        ahead = if ahead.zero? then ""
                elsif !lock.empty? && unlock_key then "TYPE-AHEAD #{ahead} - #{unlock_key} resets"
                else "TYPE-AHEAD #{ahead}"
                end
        rest = @controller.paste_rest_count
        rest = rest.zero? ? "" : "PASTE +#{rest} (#{keys_label('paste_rest')})"
        mid = [lock, @controller.insert_mode ? "INSERT" : "", ahead, rest, sel, @controller.message.to_s].reject(&:empty?).join("   ")

        # Right side, from the edge inwards: cursor position (hover: screen size), CAPS...
        right = connected ? cursor_position(st) : ""
        right_x = w - 10 - (right.size * cw)
        unless right.empty?
          status_text(right_x, text_y, right, PALETTE[:turquoise], size, cw, font)
          @status_hits.add(right_x - (cw / 2.0), y, (right.size + 1) * cw, STATUS_H, :position)
        end

        rx = right_x
        rx = draw_toggle(:caps, "CAPS", @config["caps"], rx - (cw * 2), y, cw, size, font, text_y)
        rx = draw_toggle(:fk, "FK", keybar_shown?, rx - cw, y, cw, size, font, text_y)
        rx = draw_toggle(:auto_enter, "ENTER", @controller.auto_enter?, rx - cw, y, cw, size, font, text_y)
        rx = draw_toggle(:snip, "SNIP", snippet_bar_shown?, rx - cw, y, cw, size, font, text_y)

        max_chars = [((rx - x) / cw).floor - 1, 0].max
        line = (left.ljust(24) + mid)[0, max_chars]
        fg = !lock.empty? || @controller.message ? PALETTE[:yellow] : PALETTE[:turquoise]
        line, fg = audit_line[0, max_chars], WHITE if @audit_stamp
        status_text(x, text_y, line, fg, size, cw, font)
      end

      # What the status bar says in a picture taken for audit: the full date
      # and time (with the offset from UTC), the session and who took it.
      #   "Mon 2026-11-16 14:03:27 UTC-06:00   PROD   L:host:992   USER01"
      def audit_line
        target = @controller.last_target
        where = target && @controller.connected? ? Config.display_string(target) : "not connected"
        [@audit_stamp.strftime("%a %Y-%m-%d %H:%M:%S UTC%:z"), (@tab&.title if @tab&.name || @tab&.custom_title), where,
         ENV["USERNAME"] || ENV["USER"]].compact.reject(&:empty?).join("   ")
      end

      # "05/12": cursor row/column, with as many digits as the screen size
      # needs (24 x 80: 2 and 2; 27 x 132: 2 and 3).
      def cursor_position(st)
        format("%0*d/%0*d", st.rows.to_s.size, st.cursor_row + 1, st.cols.to_s.size, st.cursor_col + 1)
      end

      # The host's response time and when it last sent anything, where the
      # host name used to be: "0.12s  at 14:03:27".
      def host_timing
        t = @controller.response_time
        heard = @controller.last_heard
        [(t < 10 ? format("%.2fs", t) : format("%.0fs", t) if t),
         ("at #{heard.strftime('%H:%M:%S')}" if heard)].compact.join("  ")
      end

      # An on/off button in the status bar, ending at `right` (CAPS: the app's
      # own Caps Lock; FK: the key bar). Returns its left edge.
      def draw_toggle(hit, label, on, right, y, cw, size, font, text_y)
        bw = cw * (label.size + 2)
        bx = right - bw
        by = y + 4
        bh = STATUS_H - 8
        if on
          @painter.fill_rect(bx, by, bw, bh, CAPS_ON)
        else
          @painter.stroke_rect(bx + 0.5, by + 0.5, bw - 1, bh - 1, OFFLINE, 1)
        end
        status_text(bx + cw, text_y, label, on ? [0x1A, 0x14, 0x05] : OFFLINE, size, cw, font)
        @status_hits.add(bx, y, bw, STATUS_H, hit)
        bx
      end

      def status_text(x, y, str, fg, size, cw, font)
        @painter.text(x, y, (str.size + 4) * cw, str, fg, font, size)
      end

      # Three bars: opens the menus when the menu bar is hidden.
      def draw_menu_icon(x, y, w, h)
        bar_w = h * 0.62
        bar_h = [h * 0.09, 1.2].max
        bx = x + ((w - bar_w) / 2.0)
        [-0.22, 0, 0.22].each do |k|
          by = y + (h / 2.0) + (k * h) - (bar_h / 2.0)
          @painter.fill_rect(bx, by, bar_w, bar_h, ICON_FG)
        end
      end

      # A status light: green = connected, amber = connecting, grey ring = offline.
      def draw_connection_icon(x, y, w, h)
        cx = x + (w / 2.0)
        cy = y + (h / 2.0)
        r = h * 0.27
        color = if @controller.connected? then ONLINE
                elsif @controller.connecting? then CONNECTING
                end
        if color
          @painter.fill_circle(cx, cy, r * 1.6, color, 0.18)
          @painter.fill_circle(cx, cy, r, color)
        else
          @painter.stroke_circle(cx, cy, r * 0.9, OFFLINE, [h * 0.09, 1.2].max)
        end
      end

      TIP_DELAY = 0.5
      TIP_BG = [0x24, 0x2D, 0x3B].freeze
      TIP_BORDER = [0x4A, 0x58, 0x6E].freeze

      def hover_status(event)
        hit = status_hit(event) || (snippet_bar_shown? && !@picker ? snippet_hover(event) : nil)
        return if hit == @hover

        was_shown = @tip_shown
        @hover = hit
        @hover_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @tip_shown = false
        redraw if was_shown
      end

      # Hides the tooltip (the pointer left, or something was clicked).
      def hide_tooltip
        was_shown = @tip_shown
        @hover = nil
        @tip_shown = false
        redraw if was_shown
      end

      # Called by the main-thread timer: shows the tooltip once the pause is up.
      def tooltip_tick
        return if @tip_shown || !@hover
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) - @hover_since < TIP_DELAY

        @tip_shown = true
        redraw
      end

      # What a status bar button does, as lines of text (the first is the heading).
      def tooltip_lines(hit)
        case hit
        when :caps
          ["CAPS: capital letters (this app only)",
           "Types letters in capitals here; your keyboard's Caps Lock is not touched.",
           "Click to turn it #{@config['caps'] ? 'off' : 'on'}."]
        when :auto_enter
          ["ENTER: keep pressing Enter to watch a job",
           "Presses Enter #{@controller.auto_enter_seconds.round(1)}s after each answer from the host, over and over.",
           "Click to #{@controller.auto_enter? ? 'stop' : 'start'}. It stops by itself if the connection ends."]
        when :fk
          ["FK: function key buttons",
           "Shows a bar of buttons: PF1-PF24, Reset, Clear, Attn, New Line and SysReq.",
           "Click to #{keybar_shown? ? 'hide' : 'show'} it."]
        when :connection
          connection_tip
        when :position
          st = @controller.snapshot&.status
          st && ["Cursor: row #{st.cursor_row + 1}, column #{st.cursor_col + 1}",
                 "Screen size: #{st.rows} x #{st.cols}"]
        when :menu
          ["Menus", "Click to open the menus."]
        when :snip
          ["SNIP: snippets",
           "Shows a list of text and key sequences you can type with a double-click.",
           "#{keys_label('snippet_picker')} finds one by name without the list. Click to #{snippet_bar_shown? ? 'hide' : 'show'} it."]
        when Array # a snippet in the sidebar: its text
          item = panel_items[hit[1]]
          if item&.script?
            [item.name, *item.text.lines.map(&:rstrip), "Script: #{File.basename(item.script)}", "Double-click to run it; Edit opens the file."]
          elsif item
            [item.name, *item.text.lines.map(&:rstrip).first(10), ("..." if item.text.lines.size > 10)].compact
          end
        end
      end

      # The status light's tooltip: state, where to, timings, what a click does.
      def connection_tip
        c = @controller
        state = if c.connected? then "Connected"
                elsif c.connecting? then "Connecting"
                else "Not connected"
                end
        target = c.last_target && Config.display_string(c.last_target)
        heading = target ? "#{state}: #{target}" : state
        t = c.response_time
        timing = [("Response time: #{format('%.2fs', t)}" if t && c.connected?),
                  ("last heard from the host at #{c.last_heard.strftime('%H:%M:%S')}" if c.last_heard && c.connected?)].compact
        [heading,
         ("Session: #{c.last_target['name']}" if c.last_target && c.last_target["name"].to_s != target),
         (timing.join(", ") unless timing.empty?),
         "Green = connected, amber = connecting, grey = not connected.",
         "Click to #{c.connected? || c.connecting? ? 'disconnect' : 'connect'}.",
         ("Scripts can attach to this session on port #{c.attach_port}." if c.attach_port)].compact
      end

      # Where the thing the tooltip describes is: [x, y, w, h].
      def tooltip_box(hit)
        hit.is_a?(Array) ? @snip_hits.rect([:row, hit[1]]) : @status_hits.rect(hit)
      end

      # The tooltip box: above a status bar button, or left of a snippet.
      def draw_tooltip(w, h)
        hit = @hover
        lines = tooltip_lines(hit)
        box = tooltip_box(hit)
        return unless lines && box

        pad = 8
        line_h = FontMetrics.for(UI_FONT)[:line] * UI_SIZE
        # The heading is bold, so it's wider; measured as drawn, or it wraps onto the next line.
        widths = lines.each_with_index.map { |t, i| FontMetrics.text_width(UI_FONT, UI_SIZE, t, bold: i.zero?).ceil + 2 }
        bw = widths.max + (2 * pad) + 6
        bh = (lines.size * line_h) + (2 * pad)
        if hit.is_a?(Array) # a snippet row: to the left of the sidebar
          bx = [box[0] - bw - 8, 4].max
          by = box[1].clamp(header_h + 4, [h - STATUS_H - bh - 6, header_h + 4].max)
        else
          bx = (box[0] + (box[2] / 2.0) - (bw / 2.0)).clamp(4, [w - bw - 4, 4].max)
          by = h - STATUS_H - bh - 6
        end
        @painter.fill_rect(bx, by, bw, bh, TIP_BG)
        @painter.stroke_rect(bx + 0.5, by + 0.5, bw - 1, bh - 1, TIP_BORDER, 1)
        lines.each_with_index do |text, i|
          @painter.text(bx + pad, by + pad + (i * line_h), widths[i] + 20, text, i.zero? ? WHITE : TITLE_FG, UI_FONT, UI_SIZE, bold: i.zero?)
        end
      end

      def status_hit(event)
        @status_hits.at(event)
      end
    end
  end
end
