# frozen_string_literal: true

require_relative "theme"

module Tn3270
  module Gui
    # The title bar a TerminalWindow draws for itself (Windows, VS Code
    # style): icon, menu names, the tabs, and the minimize / maximize / close
    # buttons. Win32::TitleBar does the window side. Included into TerminalWindow.
    module TitleBarView
      include Theme

      # Icon, menu names, window title and the minimize / maximize / close
      # buttons, across the top of the drawing area.
      def draw_title_bar(w)
        pt = @painter
        @title_hits = HitMap.new
        pt.fill_rect(0, 0, w, TITLE_H, TITLE_BG)
        draw_app_icon(12, (TITLE_H - 16) / 2.0)

        text_y = (TITLE_H - (FontMetrics.for(UI_FONT)[:line] * UI_SIZE)) / 2.0
        x = 38
        @menu_bar.names.each_with_index do |name, i|
          bw = FontMetrics.text_width(UI_FONT, UI_SIZE, name) + 16
          hit = [:menu, i]
          pt.fill_rect(x, 4, bw, TITLE_H - 8, WHITE, 0.10) if @title_hover == hit || @menu_open == i
          ui_text(x + 8, text_y, name, TITLE_FG)
          @title_hits.add(x, 0, bw, TITLE_H, hit)
          x += bw
        end

        buttons_x = w - (3 * BUTTON_W)
        draw_tabs(x + 8, buttons_x - CAPTION_MIN, 0, TITLE_H)

        %i[minimize maximize close].each_with_index do |kind, i|
          bx = buttons_x + (i * BUTTON_W)
          hover = @title_hover == [kind]
          if hover
            kind == :close ? pt.fill_rect(bx, 0, BUTTON_W, TITLE_H, CLOSE_HOVER) : pt.fill_rect(bx, 0, BUTTON_W, TITLE_H, WHITE, 0.10)
          end
          draw_window_glyph(kind, bx + (BUTTON_W / 2.0), TITLE_H / 2.0, hover && kind == :close ? WHITE : TITLE_FG)
          @title_hits.add(bx, 0, BUTTON_W, TITLE_H, [kind])
        end
      end

      # A 16px version of the app icon: a tiny 3270 screen.
      ICON_BARS = [
        [3, 3, 10, 2, [0x6C, 0x9B, 0xFF]], [3, 6, 8, 2, [0x4C, 0xE0, 0x6A]], [3, 9, 4, 2, [0x4C, 0xE0, 0x6A]],
        [8, 9, 2, 2, [0xF4, 0xFF, 0xF6]], [3, 12, 10, 1, [0x3F, 0xC8, 0xD0]]
      ].freeze

      def draw_app_icon(x, y)
        @painter.fill_rect(x, y, 16, 16, [0x24, 0x2F, 0x42])
        ICON_BARS.each { |bx, by, bw, bh, c| @painter.fill_rect(x + bx, y + by, bw, bh, c) }
      end

      def draw_window_glyph(kind, cx, cy, fg)
        pt = @painter
        case kind
        when :minimize
          pt.fill_rect(cx - 5, cy, 10, 1, fg)
        when :maximize
          if @title_bar.maximized?
            pt.stroke_rect(cx - 3.5, cy - 5.5, 8, 8, fg)
            pt.fill_rect(cx - 5.5, cy - 3.5, 8, 8, TITLE_BG)
            pt.stroke_rect(cx - 5.5, cy - 3.5, 8, 8, fg)
          else
            pt.stroke_rect(cx - 4.5, cy - 4.5, 9, 9, fg)
          end
        when :close
          pt.polyline([cx - 5, cy - 5, cx + 5, cy + 5], fg)
          pt.polyline([cx + 5, cy - 5, cx - 5, cy + 5], fg)
        end
      end

      def title_hit(event)
        return nil unless custom_title? && event[:y] < TITLE_H

        @title_hits.at(event) || [:caption]
      end

      def title_hover(hit)
        return if hit == @title_hover

        @title_hover = hit
        redraw
      end

      # Menus open on press; window buttons act on release, like Windows.
      def title_mouse_down(event, hit)
        case hit[0]
        when :menu then UI.queue_main { open_title_menu(hit[1]) }
        when :caption
          if caption_double_click?(event)
            @title_pressed = [:caption_double] # maximize / restore on the release, like the button
          elsif event[:y] < 5 && !@title_bar.maximized?
            edge = if event[:x] < 8 then :top_left
                   elsif event[:x] > event[:area_width] - 8 then :top_right
                   else :top
                   end
            UI.queue_main { @title_bar.begin_drag(edge) }
          else
            UI.queue_main { @title_bar.begin_drag(:caption) }
          end
        else
          @title_pressed = hit
        end
      end

      # Whether this caption press is the second of a double-click. Timed here,
      # not taken from event[:count]: the first press hands the mouse to the
      # Windows move loop, which eats its release, so libui never counts two.
      def caption_double_click?(event)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        last = @caption_click
        @caption_click = [now, event[:x], event[:y]]
        double = event[:count].to_i >= 2 ||
                 (last && TitleBarView.double_click?(last, @caption_click, Win32.double_click_seconds))
        @caption_click = nil if double # a third press starts over
        double
      end

      # Two presses [time, x, y] make a double-click: close enough in time and place.
      def self.double_click?(first, second, seconds, slop: 4)
        t1, x1, y1 = first
        t2, x2, y2 = second
        (t2 - t1) <= seconds && (x2 - x1).abs <= slop && (y2 - y1).abs <= slop
      end

      def title_mouse_up(event)
        pressed = @title_pressed
        @title_pressed = nil
        return @title_bar.toggle_maximize if pressed == [:caption_double]
        return unless pressed && title_hit(event) == pressed

        case pressed[0]
        when :minimize then @title_bar.minimize
        when :maximize then @title_bar.toggle_maximize
        when :close then @title_bar.close
        end
      end

      def open_title_menu(index)
        x, = @title_hits.rect([:menu, index])
        return unless x

        @menu_open = index
        redraw
        sx, sy = @title_bar.to_screen(@area.control, x, TITLE_H)
        @menu_bar.popup_submenu(index, sx, sy)
        @menu_open = nil
        @title_hover = nil
        @reshape = true
        redraw
      end
    end
  end
end
