# frozen_string_literal: true

require_relative "ui"
require_relative "../session"
require_relative "config"
require_relative "keymap"
require_relative "clipboard"
require_relative "controller"
require_relative "screen_painter"
require_relative "dialogs"
require_relative "history_window"
require_relative "find_window"
require_relative "snippet_panel"
require_relative "win32"

module Tn3270
  module Gui
    # The desktop window: a screen that scales with the window, optional PF
    # key bar, and a status bar with a menu button and a connect button.
    class App
      include ScreenPainter
      include SnippetPanel

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
      WHITE = [0xFF, 0xFF, 0xFF].freeze

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
      RECENT_FIRST = 4 # their position in the Session menu: after Connections, Connect/Disconnect, Allow Scripts, separator
      UI_FONT = Config::WINDOWS ? "Segoe UI" : "Sans"
      UI_SIZE = 9.0
      PUMP_MS = 25 # how often the main thread checks for screen changes

      def initialize(host: nil, session: nil)
        @config = Config.load
        @bindings = Keymap.bindings(@config["keys"])
        @tap = Keymap::ModifierTap.new { |mod| Win32.modifier_side(mod) }
        @controller = Controller.new(@config, on_change: -> { @dirty = true })
        @initial_host = host
        @initial_session = session
        @selection = nil # [row1, col1, row2, col2]
        @drag_anchor = nil
        @status_hits = {}
        @history_window = nil
        @painter = Painter.new
        @dirty = false
        @menu = {} # menu items by name; they hold their click handlers
      end

      def launch
        UI.init
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
        @sizing = Win32::Sizing.new(@window) { |edge, rect| shaped_rect(edge, rect) } if Win32.available?
        toggle_keybar(true) if @config["key_bar"]
        @reshape = true # start in the screen's shape
        connect_at_start
        # The worker thread only sets @dirty; libui may only be used from here.
        UI.timer(PUMP_MS) do
          pump
          1
        end
        UI.control_show(@window)
        UI.main
        quit_app
      end

      private

      attr_reader :controller, :config

      # Redraws if the worker saw a change since the last tick, and reshapes
      # the window when something asked for it.
      def pump
        # (Sizes are known after the first draw; until then the request waits.)
        if @reshape && @area_size
          @reshape = false
          fit_window_to_screen
        end
        tooltip_tick
        return unless @dirty

        @dirty = false
        # The loop can stop by itself (disconnect, keyboard error): keep the menu in step.
        sync_auto_enter_item
        redraw
        @history_window&.refresh
        @find_window&.refresh
      end

      # Status bar ENTER button / Keys > Auto Enter: press Enter over and over,
      # a pause after each answer, until switched off.
      def set_auto_enter(on)
        @controller.auto_enter = on
        sync_auto_enter_item
        redraw
      end

      def sync_auto_enter_item
        on = @controller.auto_enter?
        return if @auto_enter_shown == on

        @auto_enter_shown = on
        UI.menu_item_set_checked(@auto_enter_item, Ui.flag(on))
      end

      def redraw = @area&.redraw

      def quit_app
        return if @quitting

        @quitting = true
        @controller.shutdown
      end

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

      def item(menu, label, &block)
        it = UI.menu_append_item(menu, label)
        UI.menu_item_on_clicked(it) { block.call; nil }
        @menu[label] = it
      end

      def check_item(menu, label, checked, &block)
        it = UI.menu_append_check_item(menu, label)
        UI.menu_item_set_checked(it, Ui.flag(checked))
        UI.menu_item_on_clicked(it) { block.call(UI.menu_item_checked(it) == 1); nil }
        @menu[label] = it
      end

      def build_menus
        m = UI.new_menu("Session")
        item(m, "Connections...") { connections_dialog }
        item(m, "Connect / Disconnect") { toggle_connection }
        check_item(m, "Allow Scripts to Attach", @config["allow_attach"]) do |on|
          set_option("allow_attach", on)
          @controller.attach_setting_changed
        end
        UI.menu_append_separator(m)
        # Placeholders for saved sessions; their text is filled in on Windows
        # (see refresh_recent_menu).
        if Win32.available?
          RECENT_SLOTS.times { |i| item(m, "Session #{i + 1}") { connect_recent(i) } }
        end
        # libui puts a separator before Quit by itself.
        @menu[:quit] = UI.menu_append_quit_item(m)
        UI.on_should_quit do
          quit_app
          UI.control_destroy(@window)
          1
        end

        m = UI.new_menu("Edit")
        item(m, "Copy (selection or screen)") { copy }
        item(m, "Copy Whole Screen") { copy_screen }
        item(m, "Paste") { paste }
        UI.menu_append_separator(m)
        item(m, "Find...") { show_find }
        UI.menu_append_separator(m)
        item(m, "Snippets: Quick Pick...") { open_picker }
        item(m, "New Snippet from Selection...") { snippet_from_selection }
        UI.menu_append_separator(m)
        @caps_item = check_item(m, "Caps Lock (this app only)", @config["caps"]) { |on| set_caps(on) }

        m = UI.new_menu("Keys")
        item(m, "Keyboard Mapping...") { keys_dialog }
        @auto_enter_item = check_item(m, "Auto Enter (press Enter every #{@controller.auto_enter_seconds.round(1)}s, to watch a job)", false) do |on|
          set_auto_enter(on)
        end
        check_item(m, "Type-Ahead (queue keys while the host is busy)", @config["typeahead"]) { |on| set_option("typeahead", on) }
        check_item(m, "Numeric Fields: Digits Only", @config["numeric_lock"]) { |on| set_option("numeric_lock", on) }
        UI.menu_append_separator(m)
        %i[pa1 pa2 pa3 clear attn sysreq reset erase_input].each do |k|
          item(m, k.to_s.upcase.tr("_", " ")) { send_key(k) }
        end
        UI.menu_append_separator(m)
        (13..24).each { |n| item(m, "PF#{n}") { send_key(:"pf#{n}") } }

        m = UI.new_menu("View")
        item(m, "Screen History...") { show_history }
        item(m, "Font...") { font_dialog }
        UI.menu_append_separator(m)
        @crosshair_item = check_item(m, "Crosshair", @config["crosshair"]) { |on| set_crosshair(on) }
        @keybar_item = check_item(m, "Key Bar (PF, Reset, Clear...)", @config["key_bar"]) { |on| toggle_keybar(on) }
        @snippet_item = check_item(m, "Snippets Sidebar", @config["snippet_bar"]) { |on| toggle_snippet_bar(on) }
        check_item(m, "Underline Input Fields", @config["underline_input_fields"]) { |on| set_underline(on) }
        if Win32.available?
          UI.menu_append_separator(m)
          check_item(m, "Lock Window Shape to the Screen", @config["lock_ratio"]) { |on| set_lock_ratio(on) }
        end

        m = UI.new_menu("Help")
        item(m, "Keyboard...") { keyboard_help }
        @menu[:about] = UI.menu_append_about_item(m)
        UI.menu_item_on_clicked(@menu[:about]) do
          msg_box("About", "ruby3270 #{Tn3270::VERSION}\nA 3270 terminal in Ruby\nEngine: s3270 (x3270 suite)")
          nil
        end
      end

      # ---- window --------------------------------------------------------------

      def build_window
        @window = Ui.window("ruby3270 - not connected", 1400, 860, menubar: true, margined: false)
        UI.window_on_closing(@window) do
          quit_app
          UI.quit
          1
        end

        box = Ui.vbox(padded: false)
        @area = Ui::Area.new(draw: ->(p) { draw(p) }, mouse: ->(e) { mouse(e) },
                             key: ->(e) { key(e) }, crossed: lambda { |_left|
                               title_hover(nil)
                               hide_tooltip
                             })
        Ui.add(box, @area.control, stretchy: true)

        # Below the screen, so it never sits above the title bar.
        @keybar = Ui.grid(padded: false)
        KEYBAR.each do |label, key, col, row|
          Ui.grid_add(@keybar, Ui.button(label) { keybar_press(key) }, col, row)
        end
        Ui.add(box, @keybar)
        Ui.hide(@keybar)
        UI.window_set_child(@window, box)
      end

      # The key bar: [label, key, column, row]. PF keys in two rows, then the
      # keys that are awkward to reach on a PC keyboard.
      KEYBAR = [
        *(1..24).map { |n| ["PF#{n}", :"pf#{n}", (n - 1) % 12, (n - 1) / 12] },
        ["Reset", :reset, 12, 0], ["Clear", :clear, 13, 0], ["Attn", :attn, 14, 0],
        ["New Line", :newline, 12, 1], ["SysReq", :sysreq, 13, 1]
      ].freeze

      # A key bar button sends its key, then gives the keyboard back to the screen.
      def keybar_press(key)
        send_key(key)
        Win32.focus_control(@area.control)
      end

      def msg_box(title, text) = UI.msg_box(@window, title, text)

      # ---- drawing -------------------------------------------------------------

      # Grid placement: the screen, just under the title bar and centered
      # left to right. The status bar is pinned to the bottom of the window.
      def metrics(width, height)
        rows, cols = grid_size
        top = title_h + 4
        fit_grid(rows, cols, 0, top, width - panel_w, height - top - STATUS_H - 4, @config["font"], top: true)
      end

      def draw(params)
        pt = @painter
        pt.context = params[:context]
        w = params[:area_width]
        h = params[:area_height]
        @area_size = [w, h]
        # A new screen size (another host) reshapes the window to match.
        @reshape = true if @shaped_for && @shaped_for != grid_size
        @shaped_for ||= grid_size
        pt.fill_rect(0, 0, w, h, BACKGROUND)
        draw_title_bar(w) if custom_title?

        size, cw, ch, ox, oy = metrics(w, h)
        scr = @controller.snapshot
        font = @config["font"]

        if scr
          draw_crosshair(scr, cw, ch, ox, oy) if @config["crosshair"] && scr.status&.connected?
          paint_cells(pt, scr, size, cw, ch, ox, oy, font, underline: @config["underline_input_fields"])
          draw_find_matches(scr, cw, ch, ox, oy)
          draw_cursor(scr, cw, ch, ox, oy) if scr.status&.connected?
          draw_selection(cw, ch, ox, oy)
          # Dim the last screen once the session has ended.
          pt.fill_rect(ox, oy, cw * scr.cols, ch * scr.rows, BACKGROUND, 0.6) unless scr.status&.connected?
        end
        draw_status(scr, w, h, font)
        draw_snippet_panel(w, h) if snippet_bar_shown?
        draw_picker(w, h) if @picker
        draw_tooltip(w, h) if @tip_shown && @hover
        update_title(scr)
      end

      def draw_cursor(scr, cw, ch, ox, oy)
        x = ox + (scr.cursor_col * cw)
        y = oy + (scr.cursor_row * ch)
        if @controller.insert_mode
          @painter.fill_rect(x, y, [cw * 0.15, 2].max, ch, CURSOR)
        else
          @painter.fill_rect(x, y + (ch * 0.8), cw, ch * 0.2, CURSOR, 0.85)
        end
      end

      # Faint bands along the cursor's row and column, for lining up columns.
      def draw_crosshair(scr, cw, ch, ox, oy)
        @painter.fill_rect(ox, oy + (scr.cursor_row * ch), cw * scr.cols, ch, CROSSHAIR, 0.09)
        @painter.fill_rect(ox + (scr.cursor_col * cw), oy, cw, ch * scr.rows, CROSSHAIR, 0.09)
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
          @painter.fill_rect(x, y, len * cw, ch, FIND_HIT, current ? 0.55 : 0.28)
          @painter.stroke_rect(x, y, len * cw, ch, FIND_HIT, 1.5) if current
        end
      end

      def draw_selection(cw, ch, ox, oy)
        return unless @selection

        r1, r2 = [@selection[0], @selection[2]].minmax
        c1, c2 = [@selection[1], @selection[3]].minmax
        @painter.fill_rect(ox + (c1 * cw), oy + (r1 * ch), (c2 - c1 + 1) * cw, (r2 - r1 + 1) * ch, SELECTION, 0.35)
      end

      # The status bar, pinned across the bottom of the window: [menu]
      # [connection] host, keyboard state, insert mode, messages, and screen
      # size / cursor position on the right. Its size doesn't change with the
      # screen font size.
      def draw_status(scr, w, h, font)
        pt = @painter
        y = h - STATUS_H
        pt.fill_rect(0, y, w, STATUS_H, STATUS_BG)
        pt.fill_rect(0, y, w, 1, [0x2A, 0x33, 0x40])
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
        # Scripts can attach to this session (Session > Allow Scripts to Attach).
        if (port = @controller.attach_port)
          label = "PORT #{port}"
          rx -= (label.size + 3) * cw
          status_text(rx, text_y, label, TITLE_MUTED, size, cw, font)
        end
        rx = draw_toggle(:caps, "CAPS", @config["caps"], rx - (cw * 2), y, cw, size, font, text_y)
        rx = draw_toggle(:fk, "FK", keybar_shown?, rx - cw, y, cw, size, font, text_y)
        rx = draw_toggle(:auto_enter, "ENTER", @controller.auto_enter?, rx - cw, y, cw, size, font, text_y)
        rx = draw_toggle(:snip, "SNIP", snippet_bar_shown?, rx - cw, y, cw, size, font, text_y)

        max_chars = [((rx - x) / cw).floor - 1, 0].max
        line = (left.ljust(24) + mid)[0, max_chars]
        fg = !lock.empty? || @controller.message ? PALETTE[:yellow] : PALETTE[:turquoise]
        status_text(x, text_y, line, fg, size, cw, font)
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
        @status_hits[hit] = [bx, y, bw, STATUS_H]
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

      # ---- title bar -------------------------------------------------------------

      # Icon, menu names, window title and the minimize / maximize / close
      # buttons, across the top of the drawing area.
      def draw_title_bar(w)
        pt = @painter
        @title_hits = []
        pt.fill_rect(0, 0, w, TITLE_H, TITLE_BG)
        draw_app_icon(12, (TITLE_H - 16) / 2.0)

        text_y = (TITLE_H - (FontMetrics.for(UI_FONT)[:line] * UI_SIZE)) / 2.0
        x = 38
        @menu_bar.names.each_with_index do |name, i|
          bw = FontMetrics.text_width(UI_FONT, UI_SIZE, name) + 16
          hit = [:menu, i]
          pt.fill_rect(x, 4, bw, TITLE_H - 8, WHITE, 0.10) if @title_hover == hit || @menu_open == i
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
            kind == :close ? pt.fill_rect(bx, 0, BUTTON_W, TITLE_H, CLOSE_HOVER) : pt.fill_rect(bx, 0, BUTTON_W, TITLE_H, WHITE, 0.10)
          end
          draw_window_glyph(kind, bx + (BUTTON_W / 2.0), TITLE_H / 2.0, hover && kind == :close ? WHITE : TITLE_FG)
          @title_hits << [bx, 0, BUTTON_W, TITLE_H, [kind]]
        end
      end

      def ui_text(x, y, str, fg)
        @painter.text(x, y, FontMetrics.text_width(UI_FONT, UI_SIZE, str) + 20, str, fg, UI_FONT, UI_SIZE)
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
        hover_status(event)
      end

      # ---- status bar tooltips -----------------------------------------------------
      # libui has no tooltips for a drawing area, so they are drawn here: after
      # the pointer rests on a status bar button for TIP_DELAY seconds.

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
          ["Connection: green = connected, amber = connecting, grey = not connected",
           "Click to #{@controller.connected? || @controller.connecting? ? 'disconnect' : 'connect'}."]
        when :menu
          ["Menus", "Click to open the menus."]
        when :snip
          ["SNIP: snippets",
           "Shows a list of text and key sequences you can type with a double-click.",
           "#{keys_label('snippet_picker')} finds one by name without the list. Click to #{snippet_bar_shown? ? 'hide' : 'show'} it."]
        when Array # a snippet in the sidebar: its text
          item = panel_items[hit[1]]
          item && [item.name, *item.text.lines.map(&:rstrip).first(10), ("..." if item.text.lines.size > 10)].compact
        end
      end

      # Where the thing the tooltip describes is: [x, y, w, h].
      def tooltip_box(hit)
        return @status_hits[hit] unless hit.is_a?(Array)

        found = (@snip_hits || []).find { |*, h| h == [:row, hit[1]] }
        found && found.first(4)
      end

      # The tooltip box: above a status bar button, or left of a snippet.
      def draw_tooltip(w, h)
        hit = @hover
        lines = tooltip_lines(hit)
        box = tooltip_box(hit)
        return unless lines && box

        pad = 8
        line_h = FontMetrics.for(UI_FONT)[:line] * UI_SIZE
        widths = lines.map { |t| FontMetrics.text_width(UI_FONT, UI_SIZE, t) }
        bw = widths.max + (2 * pad) + 6
        bh = (lines.size * line_h) + (2 * pad)
        if hit.is_a?(Array) # a snippet row: to the left of the sidebar
          bx = [box[0] - bw - 8, 4].max
          by = box[1].clamp(title_h + 4, [h - STATUS_H - bh - 6, title_h + 4].max)
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

      # Menus open on press; window buttons act on release, like Windows.
      def title_mouse_down(event, hit)
        case hit[0]
        when :menu then UI.queue_main { open_title_menu(hit[1]) }
        when :caption
          if event[:count].to_i >= 2
            @title_bar.toggle_maximize
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
        sx, sy = @title_bar.to_screen(@area.control, x, TITLE_H)
        @menu_bar.popup_submenu(index, sx, sy)
        @menu_open = nil
        @title_hover = nil
        @reshape = true
        redraw
      end

      def keys_label(action) = Keymap.keys_for(@bindings, action).first || "(unbound)"

      def update_title(scr)
        host = scr&.status&.host
        title = host ? "ruby3270 - #{host}" : "ruby3270 - not connected"
        return if @title == title

        @title = title
        UI.window_set_title(@window, title)
      end

      # ---- keyboard ------------------------------------------------------------

      def key(event)
        return picker_key(event) if @picker
        return true if @snip_focus && panel_key(event)

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
        when :snippet_picker then open_picker
        when :snippet_bar then toggle_snippet_bar(!snippet_bar_shown?)
        when :snippet then run_snippet_number(action[1])
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

      # Letters follow the keyboard's Caps Lock (libui reports keys without it)
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

      # libui reports every mouse event to one handler.
      def mouse(event)
        if event[:down] == 1 then mouse_down(event)
        elsif event[:down] == 3 then right_click(event)
        elsif event[:up] == 1 then mouse_up(event)
        else
          mouse_move(event)
          mouse_drag(event) if event[:held].to_i.anybits?(1)
        end
      end

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
        hide_tooltip
        if (hit = title_hit(event))
          title_mouse_down(event, hit)
          return
        end
        return if snippet_mouse_down(event)

        if @snip_focus
          @snip_focus = false
          redraw
        end
        return unless @controller.snapshot

        @drag_anchor = cell_at(event)
        clear_selection
      end

      # Right-click with a selection: copy it, clear it, and put the cursor
      # where the pointer is. Without a selection, nothing happens.
      def right_click(event)
        return unless @selection && @controller.snapshot

        copy
        cell = cell_at(event)
        clear_selection
        @controller.move_to(*cell) if cell
      end

      def mouse_drag(event)
        return unless @drag_anchor

        cur = cell_at(event, clamp: true)
        return if @selection.nil? && cur == @drag_anchor

        @selection = [*@drag_anchor, *cur]
        redraw
      end

      def mouse_up(event)
        return title_mouse_up(event) if @title_pressed

        anchor = @drag_anchor
        @drag_anchor = nil
        return if @selection

        if anchor
          @controller.move_to(*anchor) if @controller.snapshot
        elsif (hit = status_hit(event))
          # Run after this mouse event returns; the popup menu has its own loop.
          UI.queue_main do
            case hit
            when :menu then @menu_bar.popup
            when :caps then set_caps(!@config["caps"])
            when :fk then toggle_keybar(!keybar_shown?)
            when :auto_enter then set_auto_enter(!@controller.auto_enter?)
            when :snip then toggle_snippet_bar(!snippet_bar_shown?)
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

      def keybar_shown? = Ui.visible?(@keybar)

      # Shows or hides the key bar (View menu or the FK button) and remembers it.
      def toggle_keybar(on)
        on ? Ui.show(@keybar) : Ui.hide(@keybar)
        UI.menu_item_set_checked(@keybar_item, Ui.flag(on))
        set_option("key_bar", on)
        @reshape = true
        redraw
      end

      # ---- window shape ----------------------------------------------------------

      # Height of the parts of the drawing area that aren't the screen grid
      # (title bar, margins, status bar), in drawing units.
      def chrome_h = title_h + 4 + STATUS_H + 4

      # Width / height of the screen grid at any font size.
      def grid_ratio
        rows, cols = grid_size
        fm = FontMetrics.for(@config["font"])
        (cols * fm[:advance]) / (rows * fm[:line])
      end

      # [extra window width, extra window height, pixels per drawing unit]:
      # what the window adds around the drawing area (borders, menu bar, key
      # bar), measured now, and the display scaling.
      def window_extras
        return nil unless @area_size

        win_w, win_h = Win32.window_size(@window)
        area_w, area_h = Win32.client_size(@area.control)
        return nil unless area_w.positive? && @area_size[0].positive?

        [win_w - area_w, win_h - area_h, area_w / @area_size[0].to_f]
      end

      # Outer window height that fits the screen exactly at a given outer width (and back).
      def shaped_height(width, extras)
        extra_w, extra_h, scale = extras
        ((width - extra_w - (panel_w * scale)) / grid_ratio) + (chrome_h * scale) + extra_h
      end

      def shaped_width(height, extras)
        extra_w, extra_h, scale = extras
        ((height - extra_h - (chrome_h * scale)) * grid_ratio) + extra_w + (panel_w * scale)
      end

      WMSZ_TOP = [3, 4, 5].freeze # top, top-left, top-right
      WMSZ_TOP_BOTTOM = [3, 6].freeze

      # While the user drags an edge: keep the window the shape of the screen.
      # Dragging the top or bottom edge sets the width; any other edge or corner
      # sets the height.
      def shaped_rect(edge, rect)
        return nil unless @config["lock_ratio"] && (extras = window_extras)

        left, top, right, bottom = rect
        max_w, max_h = Win32.max_window_size
        if WMSZ_TOP_BOTTOM.include?(edge)
          height = bottom - top
          width = shaped_width(height, extras)
          # Too wide for Windows to allow: the width decides instead.
          height = shaped_height(width = max_w, extras) if width > max_w
          right = left + width
          WMSZ_TOP.include?(edge) ? top = bottom - height : bottom = top + height
        else
          width = right - left
          height = shaped_height(width, extras)
          # Too tall for Windows to allow: the height decides instead.
          width = shaped_width(height = max_h, extras) if height > max_h
          [1, 4, 7].include?(edge) ? left = right - width : right = left + width # left-side edges
          WMSZ_TOP.include?(edge) ? top = bottom - height : bottom = top + height
        end
        [left, top, right, bottom]
      end

      # Snaps the window's height to the screen's shape (not when maximized).
      def fit_window_to_screen
        @shaped_for = grid_size
        return unless @config["lock_ratio"] && Win32.available? && !Win32.maximized?(@window)
        return unless (extras = window_extras)

        width, = Win32.window_size(@window)
        height = shaped_height(width, extras)
        # Keep it on the screen: too tall means narrower, and move it up if needed.
        area_x, area_y, area_w, area_h = Win32.work_area(@window)
        height = shaped_height(width = area_w, extras) if width > area_w
        width = shaped_width(height = area_h, extras) if height > area_h
        left, top = Win32.window_position(@window)
        left = left.clamp(area_x, area_x + area_w - width)
        top = top.clamp(area_y, area_y + area_h - height)
        Win32.place(@window, left, top, width, height)
      end

      def set_lock_ratio(on)
        set_option("lock_ratio", on)
        @reshape = true
      end

      def set_underline(on)
        @config["underline_input_fields"] = on
        @config.save
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
        UI.menu_item_set_checked(@caps_item, Ui.flag(on))
        redraw
      end

      def set_crosshair(on)
        set_option("crosshair", on)
        UI.menu_item_set_checked(@crosshair_item, Ui.flag(on))
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
        @connections = ConnectionsDialog.new(@config, on_connect: ->(conn) { connect_to(conn) },
                                                      on_save: -> { refresh_recent_menu })
        @connections.show
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
          "&#{i + 1}  #{c['name'].to_s.gsub('&', '&&')}\t#{Config.display_string(c)}"
        end
        @menu_bar.set_slots(labels, empty: "No saved sessions")
      end

      def keys_dialog
        @keys = KeysDialog.new(@config, on_change: -> { @bindings = Keymap.bindings(@config["keys"]); redraw })
        @keys.show
      end

      def font_dialog
        @font = FontDialog.new(@config, on_change: lambda {
          @reshape = true
          redraw
        })
        @font.show
      end

      def keyboard_help
        msg_box("Keyboard", Keymap.help(@bindings))
      end
    end
  end
end
