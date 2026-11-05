# frozen_string_literal: true

require "glimmer-dsl-libui"
require_relative "../session"
require_relative "config"
require_relative "keymap"
require_relative "clipboard"
require_relative "controller"
require_relative "screen_painter"
require_relative "dialogs"
require_relative "history_window"
require_relative "find_window"
require_relative "win32"

module Tn3270
  module Gui
    # The desktop window: a screen that scales with the window, optional PF
    # key bar, and a status bar with a menu button and a connect button.
    class App
      include Glimmer
      include DialogSupport
      include ScreenPainter

      STATUS_BG = [0x1C, 0x22, 0x2B].freeze
      CURSOR = [0xFF, 0xFF, 0xFF].freeze
      SELECTION = [0x4C, 0x8D, 0xFF].freeze
      ICON_FG = [0xC8, 0xD2, 0xE0].freeze
      ONLINE = [0x3D, 0xD6, 0x5C].freeze
      CONNECTING = [0xFF, 0xB0, 0x2E].freeze
      OFFLINE = [0x7A, 0x84, 0x94].freeze
      CAPS_ON = [0xFF, 0xC4, 0x3D].freeze
      CROSSHAIR = [0x8C, 0xB4, 0xFF].freeze
      FIND_HIT = [0xFF, 0xD2, 0x3F].freeze

      # Title bar (menus in the title bar, VS Code style)
      TITLE_H = 32
      TITLE_BG = [0x18, 0x1D, 0x25].freeze
      TITLE_FG = [0xCC, 0xD4, 0xE0].freeze
      TITLE_MUTED = [0x8A, 0x96, 0xA8].freeze
      CLOSE_HOVER = [0xE8, 0x11, 0x23].freeze
      BUTTON_W = 46
      STATUS_H = 26 # status bar height in pixels
      STATUS_FONT_SIZE = 9.5
      RECENT_SLOTS = 8 # saved sessions listed in the Session menu
      RECENT_FIRST = 3 # their position: after Connections, Connect/Disconnect, separator
      UI_FONT = Config::WINDOWS ? "Segoe UI" : "Sans"
      UI_SIZE = 9.0

      def initialize(host: nil, session: nil)
        @config = Config.load
        @bindings = Keymap.bindings(@config["keys"])
        @tap = Keymap::ModifierTap.new { |mod| Win32.modifier_side(mod) }
        @controller = Controller.new(@config, on_change: -> { changed })
        @initial_host = host
        @initial_session = session
        @selection = nil # [row1, col1, row2, col2]
        @drag_anchor = nil
        @status_hits = {}
        @history_window = nil
      end

      def launch
        build_menus
        build_window
        Win32.set_icon(@window)
        if Win32.available?
          @menu_bar = Win32::MenuBar.new(@window)
          @title_bar = Win32::TitleBar.new(@window)
          @title_bar.install if @config["custom_title_bar"] && @menu_bar.usable?
          @menu_bar.reserve_slots(0, RECENT_FIRST, RECENT_SLOTS)
          refresh_recent_menu
        end
        @menu_bar.visible = false if menu_bar_hidden?
        connect_at_start
        @window.show
      end

      private

      attr_reader :controller, :config

      # Called from the worker thread whenever something changes.
      def changed
        Glimmer::LibUI.queue_main do
          @area&.queue_redraw_all
          @history_window&.refresh
          @find_window&.refresh
        end
      end

      def redraw = @area&.queue_redraw_all

      # The menus are drawn in our own title bar (Windows).
      def custom_title? = @title_bar&.installed? || false

      def menu_bar_hidden? = (@menu_bar&.usable? && (custom_title? || @config["hide_menu_bar"])) || false

      # Menu bar hidden and no title bar menus: show the ☰ button in the status bar.
      def compact_menu? = menu_bar_hidden? && !custom_title?

      def title_h = custom_title? ? TITLE_H : 0

      def grid_size
        scr = @controller.snapshot
        scr ? [scr.rows, scr.cols] : [@controller.rows, @controller.cols]
      end

      # ---- menus ---------------------------------------------------------------

      def build_menus
        app = self
        menu("Session") {
          menu_item("Connections...") { on_clicked { app.send(:connections_dialog) } }
          menu_item("Connect / Disconnect") { on_clicked { app.send(:toggle_connection) } }
          separator_menu_item
          # Placeholders for saved sessions; their text is filled in on Windows
          # (see refresh_recent_menu).
          if Win32.available?
            RECENT_SLOTS.times do |i|
              menu_item("Session #{i + 1}") { on_clicked { app.send(:connect_recent, i) } }
            end
          end
          # LibUI puts a separator before Quit by itself.
          quit_menu_item { on_clicked { app.send(:controller).shutdown } }
        }
        menu("Edit") {
          menu_item("Copy (selection or screen)") { on_clicked { app.send(:copy) } }
          menu_item("Copy Whole Screen") { on_clicked { app.send(:copy_screen) } }
          menu_item("Paste") { on_clicked { app.send(:paste) } }
          separator_menu_item
          menu_item("Find...") { on_clicked { app.send(:show_find) } }
          separator_menu_item
          @caps_item = check_menu_item("Caps Lock (this app only)") {
            checked app.send(:config)["caps"]
            on_clicked { |item| app.send(:set_caps, item.checked) }
          }
        }
        menu("Keys") {
          menu_item("Keyboard Mapping...") { on_clicked { app.send(:keys_dialog) } }
          check_menu_item("Type-Ahead (queue keys while the host is busy)") {
            checked app.send(:config)["typeahead"]
            on_clicked { |item| app.send(:set_option, "typeahead", item.checked) }
          }
          check_menu_item("Numeric Fields: Digits Only") {
            checked app.send(:config)["numeric_lock"]
            on_clicked { |item| app.send(:set_option, "numeric_lock", item.checked) }
          }
          separator_menu_item
          %i[pa1 pa2 pa3 clear attn sysreq reset erase_input].each do |k|
            menu_item(k.to_s.upcase.tr("_", " ")) { on_clicked { app.send(:send_key, k) } }
          end
          separator_menu_item
          (13..24).each do |n|
            menu_item("PF#{n}") { on_clicked { app.send(:send_key, :"pf#{n}") } }
          end
        }
        menu("View") {
          menu_item("Screen History...") { on_clicked { app.send(:show_history) } }
          menu_item("Font...") { on_clicked { app.send(:font_dialog) } }
          separator_menu_item
          @crosshair_item = check_menu_item("Crosshair") {
            checked app.send(:config)["crosshair"]
            on_clicked { |item| app.send(:set_crosshair, item.checked) }
          }
          check_menu_item("PF Key Bar") {
            on_clicked { |item| app.send(:toggle_keybar, item.checked) }
          }
          check_menu_item("Underline Input Fields") {
            checked app.send(:config)["underline_input_fields"]
            on_clicked { |item| app.send(:set_underline, item.checked) }
          }
          if Win32.available?
            separator_menu_item
            check_menu_item("Menus in Title Bar") {
              checked app.send(:config)["custom_title_bar"]
              on_clicked { |item| app.send(:set_custom_title, item.checked) }
            }
            check_menu_item("Hide Menu Bar (menus open from ☰)") {
              checked app.send(:config)["hide_menu_bar"]
              on_clicked { |item| app.send(:set_menu_hidden, item.checked) }
            }
          end
        }
        menu("Help") {
          menu_item("Keyboard...") { on_clicked { app.send(:keyboard_help) } }
          about_menu_item { on_clicked { msg_box("About", "ruby3270 #{Tn3270::VERSION}\nA 3270 terminal in Ruby\nEngine: s3270 (x3270 suite)") } }
        }
      end

      # ---- window --------------------------------------------------------------

      def build_window
        app = self
        @window = window("ruby3270 - not connected", 1400, 860) {
          margined false
          on_closing { app.send(:controller).shutdown }

          vertical_box {
            padded false
            @area = area {
              on_draw { |params| app.send(:draw, params) }
              on_key_event { |event| app.send(:key, event) }
              on_mouse_down { |event| app.send(:mouse_down, event) }
              on_mouse_drag { |event| app.send(:mouse_drag, event) }
              on_mouse_up { |event| app.send(:mouse_up, event) }
              on_mouse_move { |event| app.send(:mouse_move, event) }
              on_mouse_exit { app.send(:title_hover, nil) }
            }

            # Below the screen, so it never sits above the title bar.
            @keybar = vertical_box {
              stretchy false
              visible false
              [(1..12), (13..24)].each do |range|
                horizontal_box {
                  range.each do |n|
                    button("PF#{n}") { on_clicked { app.send(:send_key, :"pf#{n}") } }
                  end
                }
              end
            }
          }
        }
      end

      # ---- drawing -------------------------------------------------------------

      # Grid placement: the screen, just under the title bar and centered
      # left to right. The status bar is pinned to the bottom of the window.
      def metrics(width, height)
        rows, cols = grid_size
        top = title_h + 4
        fit_grid(rows, cols, 0, top, width, height - top - STATUS_H - 4, @config["font"], top: true)
      end

      def draw(params)
        w = params[:area_width]
        h = params[:area_height]
        rectangle(0, 0, w, h) { fill rgb(BACKGROUND) }
        draw_title_bar(w) if custom_title?

        size, cw, ch, ox, oy = metrics(w, h)
        scr = @controller.snapshot
        font = @config["font"]

        if scr
          draw_crosshair(scr, cw, ch, ox, oy) if @config["crosshair"] && scr.status&.connected?
          paint_cells(scr, size, cw, ch, ox, oy, font, underline: @config["underline_input_fields"])
          draw_find_matches(scr, cw, ch, ox, oy)
          draw_cursor(scr, cw, ch, ox, oy) if scr.status&.connected?
          draw_selection(cw, ch, ox, oy)
          # Dim the last screen once the session has ended.
          rectangle(ox, oy, cw * scr.cols, ch * scr.rows) { fill rgb(BACKGROUND, 0.6) } unless scr.status&.connected?
        end
        draw_status(scr, w, h, font)
        update_title(scr)
      end

      def draw_cursor(scr, cw, ch, ox, oy)
        x = ox + (scr.cursor_col * cw)
        y = oy + (scr.cursor_row * ch)
        if @controller.insert_mode
          rectangle(x, y, [cw * 0.15, 2].max, ch) { fill rgb(CURSOR) }
        else
          rectangle(x, y + (ch * 0.8), cw, ch * 0.2) { fill rgb(CURSOR, 0.85) }
        end
      end

      # Faint bands along the cursor's row and column, for lining up columns.
      def draw_crosshair(scr, cw, ch, ox, oy)
        band = rgb(CROSSHAIR, 0.09)
        rectangle(ox, oy + (scr.cursor_row * ch), cw * scr.cols, ch) { fill band }
        rectangle(ox + (scr.cursor_col * cw), oy, cw, ch * scr.rows) { fill band }
      end

      # Every Find match in yellow; the current one stronger and outlined.
      def draw_find_matches(scr, cw, ch, ox, oy)
        return unless @find

        hits = scr.find(@find[:term], match_case: @find[:match_case])
        @find[:hits] = hits
        hits.each_with_index do |(r, c, len), i|
          current = i == @find[:index]
          x = ox + (c * cw)
          y = oy + (r * ch)
          rectangle(x, y, len * cw, ch) { fill rgb(FIND_HIT, current ? 0.55 : 0.28) }
          rectangle(x, y, len * cw, ch) { stroke rgb(FIND_HIT).merge(thickness: 1.5) } if current
        end
      end

      def draw_selection(cw, ch, ox, oy)
        return unless @selection

        r1, r2 = [@selection[0], @selection[2]].minmax
        c1, c2 = [@selection[1], @selection[3]].minmax
        rectangle(ox + (c1 * cw), oy + (r1 * ch), (c2 - c1 + 1) * cw, (r2 - r1 + 1) * ch) { fill rgb(SELECTION, 0.35) }
      end

      # The status bar, pinned across the bottom of the window: [menu]
      # [connection] host, keyboard state, insert mode, messages, and screen
      # size / cursor position on the right. Its size doesn't change with the
      # screen font size.
      def draw_status(scr, w, h, font)
        y = h - STATUS_H
        rectangle(0, y, w, STATUS_H) { fill rgb(STATUS_BG) }
        rectangle(0, y, w, 1) { fill rgb([0x2A, 0x33, 0x40]) }
        fm = FontMetrics.for(font)
        size = STATUS_FONT_SIZE
        cw = fm[:advance] * size
        text_y = y + ((STATUS_H - (fm[:line] * size)) / 2.0)
        icon_h = STATUS_H * 0.8
        icon_y = y + ((STATUS_H - icon_h) / 2.0)
        btn = STATUS_H * 1.2
        @status_hits = {}
        x = 6

        if compact_menu?
          draw_menu_icon(x, icon_y, btn, icon_h)
          @status_hits[:menu] = [x, y, btn, STATUS_H]
          x += btn
        end
        draw_connection_icon(x, icon_y, btn, icon_h)
        @status_hits[:connection] = [x, y, btn, STATUS_H]
        x += btn + (cw * 0.5)

        st = scr&.status
        connected = st&.connected?
        left = if connected then st.host.to_s
               elsif @controller.connecting? then "Connecting..."
               else "Disconnected - click the dot to connect"
               end
        lock = if !connected then ""
               elsif st.error? then "X -f"
               elsif st.keyboard_locked? || @controller.waiting_for_host? then "X SYSTEM"
               else ""
               end
        sel = @selection ? "SELECTED - #{keys_label('copy')} to copy" : ""
        ahead = @controller.typeahead_count
        ahead = ahead.positive? ? "TYPE-AHEAD #{ahead}" : ""
        mid = [lock, @controller.insert_mode ? "INSERT" : "", ahead, sel, @controller.message.to_s].reject(&:empty?).join("   ")

        # Right side, from the edge inwards: position, response time, CAPS.
        right = connected ? format("%dx%d  %03d/%03d", st.rows, st.cols, st.cursor_row + 1, st.cursor_col + 1) : ""
        right_x = w - 10 - (right.size * cw)
        status_text(right_x, text_y, right, PALETTE[:turquoise], size, cw, font) unless right.empty?

        rx = right_x
        if connected && (t = @controller.response_time)
          timing = t < 10 ? format("%.2fs", t) : format("%.0fs", t)
          rx -= (timing.size + 3) * cw
          status_text(rx, text_y, timing, TITLE_MUTED, size, cw, font)
        end
        rx = draw_caps_button(rx - (cw * 2), y, cw, size, font, text_y)

        max_chars = [((rx - x) / cw).floor - 1, 0].max
        line = (left.ljust(24) + mid)[0, max_chars]
        fg = !lock.empty? || @controller.message ? PALETTE[:yellow] : PALETTE[:turquoise]
        status_text(x, text_y, line, fg, size, cw, font)
      end

      # The app's own Caps Lock: a button ending at `right`. Returns its left edge.
      def draw_caps_button(right, y, cw, size, font, text_y)
        on = @config["caps"]
        bw = cw * 6
        bx = right - bw
        by = y + 4
        bh = STATUS_H - 8
        if on
          rectangle(bx, by, bw, bh) { fill rgb(CAPS_ON) }
        else
          rectangle(bx + 0.5, by + 0.5, bw - 1, bh - 1) { stroke rgb(OFFLINE).merge(thickness: 1) }
        end
        status_text(bx + cw, text_y, "CAPS", on ? [0x1A, 0x14, 0x05] : OFFLINE, size, cw, font)
        @status_hits[:caps] = [bx, y, bw, STATUS_H]
        bx
      end

      def status_text(x, y, str, fg, size, cw, font)
        text(x, y, (str.size + 4) * cw) {
          default_font family: font, size: size
          string(str) { color rgb(fg) }
        }
      end

      # Three bars: opens the menus when the menu bar is hidden.
      def draw_menu_icon(x, y, w, h)
        bar_w = h * 0.62
        bar_h = [h * 0.09, 1.2].max
        bx = x + ((w - bar_w) / 2.0)
        [-0.22, 0, 0.22].each do |k|
          by = y + (h / 2.0) + (k * h) - (bar_h / 2.0)
          rectangle(bx, by, bar_w, bar_h) { fill rgb(ICON_FG) }
        end
      end

      # A status light: green = connected, amber = connecting, grey ring = offline.
      def draw_connection_icon(x, y, w, h)
        cx = x + (w / 2.0)
        cy = y + (h / 2.0)
        r = h * 0.27
        if @controller.connected?
          circle(cx, cy, r * 1.6) { fill rgb(ONLINE, 0.18) }
          circle(cx, cy, r) { fill rgb(ONLINE) }
        elsif @controller.connecting?
          circle(cx, cy, r * 1.6) { fill rgb(CONNECTING, 0.18) }
          circle(cx, cy, r) { fill rgb(CONNECTING) }
        else
          pen = rgb(OFFLINE).merge(thickness: [h * 0.09, 1.2].max)
          circle(cx, cy, r * 0.9) { stroke pen }
        end
      end

      # ---- title bar -------------------------------------------------------------

      # Icon, menu names, window title and the minimize / maximize / close
      # buttons, across the top of the drawing area.
      def draw_title_bar(w)
        @title_hits = []
        rectangle(0, 0, w, TITLE_H) { fill rgb(TITLE_BG) }
        draw_app_icon(12, (TITLE_H - 16) / 2.0)

        text_y = (TITLE_H - (FontMetrics.for(UI_FONT)[:line] * UI_SIZE)) / 2.0
        x = 38
        @menu_bar.names.each_with_index do |name, i|
          bw = FontMetrics.text_width(UI_FONT, UI_SIZE, name) + 16
          hit = [:menu, i]
          rectangle(x, 4, bw, TITLE_H - 8) { fill rgb([0xFF, 0xFF, 0xFF], 0.10) } if @title_hover == hit || @menu_open == i
          ui_text(x + 8, text_y, name, TITLE_FG)
          @title_hits << [x, 0, bw, TITLE_H, hit]
          x += bw
        end

        buttons_x = w - (3 * BUTTON_W)
        title = @title.to_s
        tw = FontMetrics.text_width(UI_FONT, UI_SIZE, title)
        tx = [(w - tw) / 2.0, x + 16].max
        ui_text(tx, text_y, title, TITLE_MUTED) if tx + tw < buttons_x - 8

        %i[minimize maximize close].each_with_index do |kind, i|
          bx = buttons_x + (i * BUTTON_W)
          hover = @title_hover == [kind]
          if hover
            bg = kind == :close ? CLOSE_HOVER : [0xFF, 0xFF, 0xFF]
            rectangle(bx, 0, BUTTON_W, TITLE_H) { fill rgb(bg, kind == :close ? 1.0 : 0.10) }
          end
          draw_window_glyph(kind, bx + (BUTTON_W / 2.0), TITLE_H / 2.0, hover && kind == :close ? [0xFF, 0xFF, 0xFF] : TITLE_FG)
          @title_hits << [bx, 0, BUTTON_W, TITLE_H, [kind]]
        end
      end

      def ui_text(x, y, str, fg)
        text(x, y, FontMetrics.text_width(UI_FONT, UI_SIZE, str) + 20) {
          default_font family: UI_FONT, size: UI_SIZE
          string(str) { color rgb(fg) }
        }
      end

      # A 16px version of the app icon: a tiny 3270 screen.
      ICON_BARS = [
        [3, 3, 10, 2, [0x6C, 0x9B, 0xFF]], [3, 6, 8, 2, [0x4C, 0xE0, 0x6A]], [3, 9, 4, 2, [0x4C, 0xE0, 0x6A]],
        [8, 9, 2, 2, [0xF4, 0xFF, 0xF6]], [3, 12, 10, 1, [0x3F, 0xC8, 0xD0]]
      ].freeze

      def draw_app_icon(x, y)
        rectangle(x, y, 16, 16) { fill rgb([0x24, 0x2F, 0x42]) }
        ICON_BARS.each do |bx, by, bw, bh, c|
          rectangle(x + bx, y + by, bw, bh) { fill rgb(c) }
        end
      end

      def draw_window_glyph(kind, cx, cy, fg)
        pen = rgb(fg).merge(thickness: 1)
        case kind
        when :minimize
          rectangle(cx - 5, cy, 10, 1) { fill rgb(fg) }
        when :maximize
          if @title_bar.maximized?
            rectangle(cx - 3.5, cy - 5.5, 8, 8) { stroke pen }
            rectangle(cx - 5.5, cy - 3.5, 8, 8) { fill rgb(TITLE_BG); stroke pen }
          else
            rectangle(cx - 4.5, cy - 4.5, 9, 9) { stroke pen }
          end
        when :close
          polyline(cx - 5, cy - 5, cx + 5, cy + 5) { stroke pen }
          polyline(cx + 5, cy - 5, cx - 5, cy + 5) { stroke pen }
        end
      end

      def title_hit(event)
        return nil unless custom_title? && event[:y] < TITLE_H

        hit = (@title_hits || []).find { |x, y, w, h, _| event[:x].between?(x, x + w) && event[:y].between?(y, y + h) }
        hit ? hit[4] : [:caption]
      end

      def title_hover(hit)
        return if hit == @title_hover

        @title_hover = hit
        redraw
      end

      def mouse_move(event)
        title_hover(title_hit(event)) if custom_title?
      end

      # Menus open on press; window buttons act on release, like Windows.
      def title_mouse_down(event, hit)
        case hit[0]
        when :menu then Glimmer::LibUI.queue_main { open_title_menu(hit[1]) }
        when :caption
          if event[:count].to_i >= 2
            @title_bar.toggle_maximize
          elsif event[:y] < 5 && !@title_bar.maximized?
            edge = if event[:x] < 8 then :top_left
                   elsif event[:x] > event[:area_width] - 8 then :top_right
                   else :top
                   end
            Glimmer::LibUI.queue_main { @title_bar.begin_drag(edge) }
          else
            Glimmer::LibUI.queue_main { @title_bar.begin_drag(:caption) }
          end
        else
          @title_pressed = hit
        end
      end

      def title_mouse_up(event)
        pressed = @title_pressed
        @title_pressed = nil
        return unless pressed && title_hit(event) == pressed

        case pressed[0]
        when :minimize then @title_bar.minimize
        when :maximize then @title_bar.toggle_maximize
        when :close then @title_bar.close
        end
      end

      def open_title_menu(index)
        x, = (@title_hits || []).find { |*, hit| hit == [:menu, index] }
        return unless x

        @menu_open = index
        redraw
        sx, sy = @title_bar.to_screen(@area, x, TITLE_H)
        @menu_bar.popup_submenu(index, sx, sy)
        @menu_open = nil
        @title_hover = nil
        redraw
      end

      def keys_label(action) = Keymap.keys_for(@bindings, action).first || "(unbound)"

      def update_title(scr)
        host = scr&.status&.host
        title = host ? "ruby3270 - #{host}" : "ruby3270 - not connected"
        return if @title == title

        @title = title
        @window.title = title
      end

      # ---- keyboard ------------------------------------------------------------

      def key(event)
        tap = @tap.feed(event)
        return perform(Keymap.action_result(@bindings[tap])) if tap && @bindings[tap]

        action = Keymap.translate(event, @bindings)
        return false unless action

        perform(action)
      end

      def perform(action)
        case action[0]
        when :history then show_history
        when :find then show_find
        when :crosshair then set_crosshair(!@config["crosshair"])
        when :caps then set_caps(!@config["caps"])
        when :copy then copy
        when :paste then paste
        when :key
          clear_selection
          @controller.press(action[1])
        when :type
          clear_selection
          @controller.type(apply_caps(action[1]))
        end
        true
      end

      # Letters follow the keyboard's Caps Lock (LibUI reports keys without it)
      # and, on top of that, the app's own Caps Lock.
      def apply_caps(char)
        return char unless char.match?(/\A[[:alpha:]]\z/)

        char = char.swapcase if Win32.caps_lock_on?
        @config["caps"] ? char.upcase : char
      end

      def send_key(key)
        clear_selection
        @controller.press(key)
      end

      # ---- mouse: click moves the cursor, drag selects a block ------------------

      def cell_at(event, clamp: false)
        rows, cols = grid_size
        _, cw, ch, ox, oy = metrics(event[:area_width], event[:area_height])
        col = ((event[:x] - ox) / cw).floor
        row = ((event[:y] - oy) / ch).floor
        return [row.clamp(0, rows - 1), col.clamp(0, cols - 1)] if clamp
        return nil unless row.between?(0, rows - 1) && col.between?(0, cols - 1)

        [row, col]
      end

      def mouse_down(event)
        return unless event[:down] == 1

        if (hit = title_hit(event))
          title_mouse_down(event, hit)
          return
        end
        return unless @controller.snapshot

        @drag_anchor = cell_at(event)
        clear_selection
      end

      def mouse_drag(event)
        return unless @drag_anchor && (event[:held].to_i & 1) == 1

        cur = cell_at(event, clamp: true)
        return if @selection.nil? && cur == @drag_anchor

        @selection = [*@drag_anchor, *cur]
        redraw
      end

      def mouse_up(event)
        return unless event[:up] == 1
        return title_mouse_up(event) if @title_pressed

        anchor = @drag_anchor
        @drag_anchor = nil
        return if @selection

        if anchor
          @controller.move_to(*anchor) if @controller.snapshot
        elsif (hit = status_hit(event))
          # Run after this mouse event returns; the popup menu has its own loop.
          Glimmer::LibUI.queue_main do
            case hit
            when :menu then @menu_bar.popup
            when :caps then set_caps(!@config["caps"])
            else toggle_connection
            end
          end
        end
      end

      def status_hit(event)
        @status_hits.find do |_, (x, y, w, h)|
          event[:x].between?(x, x + w) && event[:y].between?(y, y + h)
        end&.first
      end

      def clear_selection
        return unless @selection

        @selection = nil
        redraw
      end

      # ---- connection ----------------------------------------------------------

      # Disconnects if connected; otherwise reconnects to the last host, or
      # opens the connections dialog if there isn't one.
      def toggle_connection
        if @controller.connected? || @controller.connecting?
          @controller.disconnect
          return redraw
        end

        target = @controller.last_target ||
                 @config.connections.find { |c| c["name"] == @config["last_connection"] } ||
                 @config.connections.first
        return connections_dialog unless target

        saved = @config.connections.any? { |c| c["name"] == target["name"] }
        saved ? connect_to(target) : @controller.connect(target)
      end

      # ---- clipboard -----------------------------------------------------------

      def copy
        scr = @controller.snapshot
        return unless scr

        Clipboard.copy(@selection ? scr.region_text(*@selection) : scr.text)
      end

      def copy_screen
        scr = @controller.snapshot
        Clipboard.copy(scr.text) if scr
      end

      def paste = @controller.paste(Clipboard.paste)

      # ---- view options --------------------------------------------------------

      def toggle_keybar(on)
        @keybar.visible = on
      end

      def set_underline(on)
        @config["underline_input_fields"] = on
        @config.save
        redraw
      end

      def set_menu_hidden(on)
        @config["hide_menu_bar"] = on
        @config.save
        @menu_bar&.visible = !menu_bar_hidden?
        redraw
      end

      def set_option(key, on)
        @config[key] = on
        @config.save
      end

      # The app's own Caps Lock; the keyboard's Caps Lock is left alone, so
      # other programs are unaffected.
      def set_caps(on)
        set_option("caps", on)
        @caps_item.checked = on if @caps_item
        redraw
      end

      def set_crosshair(on)
        set_option("crosshair", on)
        @crosshair_item.checked = on if @crosshair_item
        redraw
      end

      # ---- find ------------------------------------------------------------------

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

      def set_custom_title(on)
        @config["custom_title_bar"] = on
        @config.save
        on ? @title_bar&.install : @title_bar&.uninstall
        @menu_bar&.visible = !menu_bar_hidden?
        @title_hover = nil
        redraw
      end

      # ---- other windows -------------------------------------------------------

      def show_history
        if @history_window&.open?
          @history_window.focus
        else
          @history_window = HistoryWindow.new(@controller, @config,
                                              on_close: -> { @history_window = nil },
                                              on_paste: lambda { |text|
                                                clear_selection
                                                @controller.paste(text)
                                                Win32.focus(@window)
                                              })
          @history_window.show
        end
      end

      def connections_dialog
        ConnectionsDialog.new(@config, on_connect: ->(conn) { connect_to(conn) },
                                       on_save: -> { refresh_recent_menu }).show
      end

      # ---- saved sessions in the Session menu ------------------------------------

      # bin/tn3270 --session NAME connects to that saved session; a name that
      # isn't saved is tried as host:port.
      def connect_at_start
        if @initial_session
          conn = @config.connections.find { |c| c["name"].to_s.casecmp?(@initial_session.strip) }
          conn ? connect_to(conn) : @controller.connect(@initial_session)
        elsif @initial_host
          @controller.connect(@initial_host)
        end
      end

      # Connects to a saved connection and moves it to the top of the menu.
      def connect_to(conn)
        name = conn["name"].to_s
        @config["last_connection"] = name
        @config["recent"] = ([name] + Array(@config["recent"]) - [""]).uniq.first(50)
        @config.save
        refresh_recent_menu
        @controller.connect(conn)
      end

      def connect_recent(index)
        conn = @recent_list && @recent_list[index]
        conn ? connect_to(conn) : connections_dialog
      end

      # Saved connections, most recently used first.
      def recent_connections
        order = Array(@config["recent"])
        @config.connections.each_with_index
               .sort_by { |c, i| [order.index(c["name"]) || order.size, i] }
               .map(&:first)
      end

      def refresh_recent_menu
        return unless @menu_bar

        @recent_list = recent_connections.first(RECENT_SLOTS)
        labels = @recent_list.each_with_index.map do |c, i|
          "&#{i + 1}  #{c['name'].to_s.gsub('&', '&&')}\t#{Config.connect_string(c)}"
        end
        @menu_bar.set_slots(labels, empty: "No saved sessions")
      end

      def keys_dialog
        KeysDialog.new(@config, on_change: -> { @bindings = Keymap.bindings(@config["keys"]); redraw }).show
      end

      def font_dialog
        FontDialog.new(@config, on_change: -> { redraw }).show
      end

      def keyboard_help
        msg_box("Keyboard", Keymap.help(@bindings))
      end
    end
  end
end
