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
require_relative "spell_ui"
require_relative "win32"
require_relative "tab"
require_relative "settings_transfer"

module Tn3270
  module Gui
    # One desktop window: a strip of session tabs, the active tab's screen
    # (it scales with the window), an optional PF key bar, and a status bar
    # with a menu button and a connect button. Program owns the windows and
    # the menus they share; each Tab owns its connection.
    class TerminalWindow
      include ScreenPainter
      include SnippetPanel
      include SpellUi

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
      TAB_STRIP_H = 32 # without the custom title bar, the tabs get a row of their own
      CAPTION_MIN = 48 # title bar width kept free of tabs, for dragging the window
      UI_FONT = Config::WINDOWS ? "Segoe UI" : "Sans"
      UI_SIZE = 9.0
      SCREEN_PAD = 5 # blank margin (pixels) around the mainframe screen

      attr_reader :tabs

      # `tabs`: the tabs it starts with (moved from another window), or nil
      # for one new, empty tab.
      def initialize(program, tabs: nil)
        @program = program
        @config = program.config
        @tap = Keymap::ModifierTap.new { |mod| Win32.modifier_side(mod) }
        @tabs = tabs ? tabs.dup : [Tab.new(@config)]
        @tab = @tabs.first
        @controller = @tab.controller
        @selection = @tab.selection # [row1, col1, row2, col2]
        @drag_anchor = nil
        @status_hits = {}
        @tab_hits = []
        @start_hits = []
        @history_window = nil
        @painter = Painter.new
      end

      # Builds the window and shows it, at `rect` ([left, top, width, height]
      # in outer pixels) if given.
      def launch(rect: nil)
        build_window
        Win32.set_icon(@window)
        if Win32.available?
          @menu_bar = Win32::MenuBar.new(@window)
          @title_bar = Win32::TitleBar.new(@window)
          @title_bar.install if @config["custom_title_bar"] && @menu_bar.usable?
        end
        @menu_bar.visible = false if menu_bar_hidden?
        @sizing = Win32::Sizing.new(@window) { |edge, rect| shaped_rect(edge, rect) } if Win32.available?
        toggle_keybar(true) if @config["key_bar"]
        Win32.place(@window, *rect) if rect && Win32.available?
        @reshape = true # start in the screen's shape
        UI.control_show(@window)
        focus_screen
      end

      # Runs one of this window's commands (the menus and Program use this).
      def command(name, *args) = send(name, *args)

      def ui_window = @window
      def hwnd_ptr = @window.to_i # libui's window pointer, as menu clicks report it
      def hwnd_i = Win32.hwnd(@window).to_i

      # Called by Program's timer. Redraws if a tab's worker saw a change, and
      # reshapes the window when something asked for it.
      def pump
        # (Sizes are known after the first draw; until then the request waits.)
        if @reshape && @area_size && !@program.floating?(self)
          keep = @reshape == :height ? :height : :width
          @reshape = false
          fit_window_to_screen(keep: keep)
        end
        tooltip_tick
        # Every tab, not just the one shown: their status lights are in the strip.
        return unless @tabs.map(&:take_dirty).any?

        refresh_spelling(redraw: false)
        redraw
        @history_window&.refresh
        @find_window&.refresh
      end

      # Closes the window without ending its sessions (they were moved away).
      def destroy
        close_child_windows
        UI.control_destroy(@window)
      end

      # ---- tabs ------------------------------------------------------------------

      # Puts a tab in this window (new, or moved from another) and shows it.
      def add_tab(tab, index: @tabs.size, select: true)
        @tabs.insert(index.clamp(0, @tabs.size), tab)
        select_tab(tab) if select
        redraw
      end

      # Takes a tab out of this window (closed, or moving to another). Its
      # session keeps running. The tab next to it is shown instead.
      def remove_tab(tab)
        i = @tabs.index(tab)
        return unless i

        tab.selection = @selection if tab.equal?(@tab)
        @tabs.delete_at(i)
        if tab.equal?(@tab)
          @tab = nil
          select_tab(@tabs[[i, @tabs.size - 1].min]) unless @tabs.empty?
        end
        redraw
      end

      # The tab strip in screen pixels: [left, top, right, bottom], or nil
      # before the first draw.
      def strip_rect_px
        return nil unless @strip && Win32.available?

        x0, x1, y0, y1 = @strip
        s = px_scale
        l, t = Win32.client_to_screen(@area.control, x0 * s, y0 * s)
        [l, t, l + ((x1 - x0) * s).round, t + ((y1 - y0) * s).round]
      end

      def strip_x0_px = strip_rect_px&.first

      # Screen x of a tab's left edge.
      def tab_left_px(tab)
        i = @tabs.index(tab)
        return nil unless i && @strip

        _, lefts = TabStrip.layout(@tabs.size, @strip[0], @strip[1])
        Win32.client_to_screen(@area.control, lefts[i] * px_scale, 0)[0]
      end

      # Where a tab dropped in at screen x would go.
      def insert_index_px(px)
        return @tabs.size unless @strip

        width, lefts = TabStrip.layout(@tabs.size, @strip[0], @strip[1])
        TabStrip.insert_index(lefts, width, area_x(px))
      end

      # A tab being dragged along the strip with its left edge at screen x
      # `left_px` (nil: the drag is over). The other tabs make way.
      def drag_tab(tab, left_px)
        if left_px.nil? || !@strip
          @drag_x = nil
          return redraw
        end

        @drag_x = area_x(left_px)
        width, lefts = TabStrip.layout(@tabs.size, @strip[0], @strip[1])
        from = @tabs.index(tab)
        to = from && TabStrip.drop_index(lefts, width, from, @drag_x)
        @tabs = TabStrip.move(@tabs, from, to) if from && to != from
        redraw
      end

      private

      attr_reader :controller, :config

      def bindings = @program.bindings

      def select_tab(tab)
        return if tab.nil? || tab.equal?(@tab)

        @tab&.selection = @selection
        @tab = tab
        @controller = tab.controller
        @selection = tab.selection
        @drag_anchor = nil
        @picker = nil
        @find[:index] = nil if @find
        @history_window&.controller = @controller
        @find_window&.refresh
        refresh_spelling(redraw: false)
        sync_menu_checks
        redraw
      end

      def new_tab
        tab = Tab.new(@config)
        tab.opened_from = @tab
        add_tab(tab, index: (@tabs.index(@tab) || -1) + 1)
        tab
      end

      # A new tab on the same session as `tab` (right-click > Duplicate Tab).
      def duplicate_tab(tab = @tab)
        return unless tab&.controller&.last_target

        new_tab
        duplicate_session(tab)
      end

      # Connects this tab to the session `source` is on.
      def duplicate_session(source)
        target = source.controller.last_target
        @config.connections.include?(target) ? connect_to(target) : @controller.connect(target)
      end

      # The tab whose session the new tab page offers to open again: the one
      # this tab was opened from, if it's still open and has a session.
      def duplicate_source
        src = @tab&.opened_from
        src && src.controller.last_target && @program.open_tab?(src) ? src : nil
      end

      # Rename Tab (or a double-click on it): the tab's name turns into a text
      # box right there. Enter keeps it, Esc cancels, a click elsewhere keeps
      # it. An empty name goes back to the session's name.
      def rename_tab(tab = @tab)
        return unless tab && @tabs.include?(tab)

        select_tab(tab)
        @tab_edit = { tab: tab, text: +tab.title, all: true } # all: the whole name is selected
        redraw
      end

      def tab_edit_key(event)
        edit = @tab_edit
        case text_box_key(event)
        when :escape then @tab_edit = nil
        when :enter then finish_tab_edit
        when :backspace
          edit[:all] ? edit[:text] = +"" : edit[:text].chop!
          edit[:all] = false
        when Array
          step = text_box_key(event)
          edit[:all] ? edit[:text] = +step[1] : edit[:text] << step[1]
          edit[:all] = false
        end
        redraw
        true
      end

      # Keeps the typed name (unless it's unchanged).
      def finish_tab_edit
        edit = @tab_edit or return
        @tab_edit = nil
        tab = edit[:tab]
        text = edit[:text].strip
        tab.custom_title = text unless text == tab.title
        update_title(@controller.snapshot)
        redraw
      end

      # Closes a tab and ends its session. The last tab closes the window.
      def close_tab(tab = @tab)
        return unless tab
        return close_window if @tabs.size == 1

        remove_tab(tab)
        @program.retire(tab)
      end

      # Like the window's close button: the sessions in it end.
      def close_window
        if Win32.available?
          @title_bar.close # posts WM_CLOSE, so on_closing runs as usual
        else
          close_child_windows
          @program.window_closed(self)
          UI.control_destroy(@window)
        end
      end

      def step_tab(step)
        i = @tabs.index(@tab) || 0
        select_tab(@tabs[(i + step) % @tabs.size])
      end

      def next_tab = step_tab(1)
      def prev_tab = step_tab(-1)
      def tab_to_new_window(tab = @tab) = @program.tab_to_new_window(self, tab)
      def new_window = @program.new_window

      def close_child_windows
        @history_window.close if @history_window&.open?
        @find_window.close if @find_window&.open?
      end

      # Pixels per drawing unit (display scaling).
      def px_scale
        return 1.0 unless @area_size && Win32.available? && @area_size[0].positive?

        Win32.client_size(@area.control)[0] / @area_size[0].to_f
      end

      # Screen x (pixels) -> drawing area x.
      def area_x(px) = (px - Win32.client_to_screen(@area.control, 0, 0)[0]) / px_scale

      def focus_screen = Win32.focus_control(@area.control)

      def sync_menu_checks
        @program.sync_check(:auto_enter, @controller.auto_enter?)
      end

      # ---- drawing the tabs ----------------------------------------------------------

      TAB_HOVER = [0xFF, 0xFF, 0xFF].freeze

      # Without the custom title bar: a row across the top for the tabs.
      def draw_strip_row(w)
        @painter.fill_rect(0, 0, w, TAB_STRIP_H, TITLE_BG)
        draw_tabs(8, w - 8, 0, TAB_STRIP_H)
      end

      # The tabs between x0 and x1, then the + button. A tab being dragged
      # follows the mouse, drawn last so it's on top.
      def draw_tabs(x0, x1, top, h)
        @strip = [x0, x1, top, top + h]
        @tab_hits = []
        @tab_edit = nil if @tab_edit && !@tabs.include?(@tab_edit[:tab]) # moved or closed meanwhile
        width, lefts = TabStrip.layout(@tabs.size, x0, x1)
        dragged = @program.strip_drag(self)
        @tabs.each_with_index do |tab, i|
          next if tab.equal?(dragged) && @drag_x
          next if lefts[i] + width > x1 + TabStrip::NEW_W # no room left

          draw_tab(tab, i, lefts[i], top, width, h)
        end
        draw_new_tab_button((lefts.last || x0) + (lefts.empty? ? 0 : width), top, h)
        return unless dragged && @drag_x

        draw_tab(dragged, @tabs.index(dragged), @drag_x.clamp(x0, [x1 - width, x0].max), top, width, h)
      end

      def draw_tab(tab, index, x, top, width, h)
        pt = @painter
        y = top + 5
        th = h - 5
        active = tab.equal?(@tab)
        hover = @tab_hover && @tab_hover[1] == index && @tab_hover[0] != :new_tab
        if active
          pt.fill_rect(x, y, width, th, error_locked? ? LOCKED_BACKGROUND : BACKGROUND)
        elsif hover
          pt.fill_rect(x, y, width, th, TAB_HOVER, 0.07)
        else
          pt.fill_rect(x + width - 1, y + 7, 1, th - 14, TITLE_MUTED, 0.35) # divider
        end
        color = { connected: ONLINE, connecting: CONNECTING }[tab.state]
        cy = y + (th / 2.0)
        color ? pt.fill_circle(x + 13, cy, 3.5, color) : pt.stroke_circle(x + 13, cy, 3.2, OFFLINE, 1.2)
        text_y = y + ((th - ui_line_h) / 2.0)
        if @tab_edit && @tab_edit[:tab].equal?(tab)
          @tab_hits << [x, y, width, th, [:tab, index]]
          return draw_tab_edit(x + 21, y + 4, [width - 21 - 6, 40].max, th - 8, text_y)
        end

        ui_text(x + 23, text_y, fit_text(tab.title, width - 23 - 26), active ? WHITE : TITLE_FG) if width >= 60
        if (active || hover) && width >= 60
          cx = x + width - 15
          if @tab_hover == [:tab_close, index]
            pt.fill_rect(cx - 8, cy - 8, 16, 16, TAB_HOVER, 0.14)
          end
          pt.polyline([cx - 4, cy - 4, cx + 4, cy + 4], TITLE_FG)
          pt.polyline([cx + 4, cy - 4, cx - 4, cy + 4], TITLE_FG)
          @tab_hits << [cx - 8, cy - 8, 16, 16, [:tab_close, index]]
        end
        @tab_hits << [x, y, width, th, [:tab, index]]
      end

      # The name being edited, in a box over the tab's title: the whole name
      # highlighted until you type, then a caret at the end. A long name
      # shows its end, where you're typing.
      def draw_tab_edit(x, y, w, h, text_y)
        pt = @painter
        pt.fill_rect(x, y, w, h, SnippetPanel::FIELD_BG)
        pt.stroke_rect(x + 0.5, y + 0.5, w - 1, h - 1, SELECTION, 1)
        shown = @tab_edit[:text].dup
        width = ->(s) { FontMetrics.text_width(UI_FONT, UI_SIZE, s) }
        shown = shown[1..] while !shown.empty? && width.call(shown) > w - 14
        tw = width.call(shown)
        pt.fill_rect(x + 5, text_y, tw + 2, ui_line_h, SELECTION, 0.55) if @tab_edit[:all] && !shown.empty?
        ui_text(x + 6, text_y, shown, WHITE)
        pt.fill_rect(x + 7 + tw, text_y + 1, 1, ui_line_h - 2, TITLE_FG) unless @tab_edit[:all]
      end

      def draw_new_tab_button(x, top, h)
        cx = x + (TabStrip::NEW_W / 2.0)
        cy = top + 5 + ((h - 5) / 2.0)
        @painter.fill_rect(cx - 12, cy - 12, 24, 24, TAB_HOVER, 0.10) if @tab_hover == [:new_tab]
        @painter.fill_rect(cx - 6, cy - 0.5, 12, 1.2, TITLE_FG)
        @painter.fill_rect(cx - 0.5, cy - 6, 1.2, 12, TITLE_FG)
        @tab_hits << [cx - 12, cy - 12, 24, 24, [:new_tab]]
      end

      # ---- tab clicks ------------------------------------------------------------------

      def tab_hit(event) = hit_at(@tab_hits, event)

      # A press on a tab shows it and may start a drag; × and + act on release.
      def tab_mouse_down(event, hit)
        case hit[0]
        when :tab
          tab = @tabs[hit[1]]
          if @tab_edit && @tab_edit[:tab].equal?(tab)
            @tab_edit[:all] = false # a click in the name being edited: just stop selecting it all
            return redraw
          end
          finish_tab_edit
          select_tab(tab)
          # The release may come anywhere (even over another window): it
          # mustn't count as a click on whatever is under it here.
          @tab_down = true
          if event[:count].to_i < 2
            @program.begin_tab_drag(self, tab)
          else
            UI.queue_main { rename_tab(tab) } # double-click: rename it
          end
        else
          @tab_pressed = hit
        end
      end

      def tab_mouse_up(event)
        pressed = @tab_pressed
        @tab_pressed = nil
        return unless tab_hit(event) == pressed

        case pressed[0]
        when :tab_close then UI.queue_main { close_tab(@tabs[pressed[1]]) }
        when :new_tab then new_tab
        end
      end

      # Middle-click on a tab closes it, as in a browser.
      def middle_click(event)
        hit = tab_hit(event)
        return unless hit && %i[tab tab_close].include?(hit[0])

        tab = @tabs[hit[1]]
        UI.queue_main { close_tab(tab) }
      end

      def tab_hover_at(event)
        hit = tab_hit(event)
        return if hit == @tab_hover

        @tab_hover = hit
        redraw
      end

      # Right-click on a tab.
      def tab_menu(tab)
        many = @tabs.size > 1
        items = ["New Tab", ["Duplicate Tab", !tab.controller.last_target.nil?], "Rename Tab",
                 ["Move Tab to New Window", many], nil, "Close Tab", ["Close Other Tabs", many]]
        case Win32.choose(@area.control, items)
        when 0 then new_tab
        when 1 then duplicate_tab(tab)
        when 2 then rename_tab(tab)
        when 3 then tab_to_new_window(tab)
        when 5 then close_tab(tab)
        when 6 then (@tabs - [tab]).each { |t| close_tab(t) }
        end
      end

      # ---- the new tab page --------------------------------------------------------------
      # A tab that hasn't connected yet lists the saved sessions to open.

      START_W = 460
      START_ROW_H = 44

      # (The engine reports a blank screen even before connecting, so "new"
      # means the tab has never been asked to connect anywhere.)
      def start_page? = @controller.last_target.nil? && !@controller.connecting?

      def draw_start_page(w)
        pt = @painter
        @start_hits = []
        sessions = recent_connections.first(9)
        x = [((w - panel_w - START_W) / 2.0), 16].max
        y = header_h + 48
        pt.text(x, y, START_W, "Open a session", WHITE, UI_FONT, UI_SIZE * 1.5, bold: true)
        y += 40
        if (src = duplicate_source)
          hover = @start_hover == [:duplicate]
          pt.fill_rect(x, y, START_W, START_ROW_H - 4, SELECTION, hover ? 0.30 : 0.18)
          ui_text(x + 12, y + 12, "D", TITLE_MUTED)
          ui_text(x + 36, y + 4, fit_text("Duplicate \"#{src.title}\"", START_W - 48), WHITE)
          ui_text(x + 36, y + 4 + ui_line_h, "Another connection to the session in the tab you came from", TITLE_MUTED)
          @start_hits << [x, y, START_W, START_ROW_H - 4, [:duplicate]]
          y += START_ROW_H + 12
        end
        if sessions.empty?
          ui_text(x, y, "No saved sessions yet.", TITLE_MUTED)
          y += 30
        end
        sessions.each_with_index do |conn, i|
          hover = @start_hover == [:session, i]
          pt.fill_rect(x, y, START_W, START_ROW_H - 4, TAB_HOVER, hover ? 0.10 : 0.04)
          ui_text(x + 12, y + 12, (i + 1).to_s, TITLE_MUTED)
          ui_text(x + 36, y + 4, fit_text(conn["name"].to_s, START_W - 48), WHITE)
          ui_text(x + 36, y + 4 + ui_line_h, fit_text(Config.display_string(conn), START_W - 48), TITLE_MUTED)
          @start_hits << [x, y, START_W, START_ROW_H - 4, [:session, i]]
          y += START_ROW_H
        end
        label = "Connections..."
        bw = FontMetrics.text_width(UI_FONT, UI_SIZE, label) + 24
        hover = @start_hover == [:connections]
        pt.fill_rect(x, y + 8, bw, 28, TAB_HOVER, hover ? 0.16 : 0.08)
        ui_text(x + 12, y + 14, label, TITLE_FG)
        @start_hits << [x, y + 8, bw, 28, [:connections]]
        hint = "Press 1-#{[sessions.size, 1].max} to open, or #{keys_label('new_tab')} for another tab"
        ui_text(x + bw + 16, y + 14, hint, TITLE_MUTED) unless sessions.empty?
      end

      def start_page_click(hit)
        case hit[0]
        when :session then (conn = recent_connections[hit[1]]) && connect_to(conn)
        when :connections then UI.queue_main { connections_dialog }
        when :duplicate then (src = duplicate_source) && duplicate_session(src)
        end
      end

      # 1-9 on the new tab page opens that session, D duplicates. True if it did.
      def start_page_number(char)
        if char.casecmp?("d") && (src = duplicate_source)
          duplicate_session(src)
          return true
        end
        return false unless char.match?(/\A[1-9]\z/)

        conn = recent_connections.first(9)[char.to_i - 1]
        conn && connect_to(conn)
        !conn.nil?
      end

      def start_hover_at(event)
        hit = start_page? ? hit_at(@start_hits, event) : nil
        return if hit == @start_hover

        @start_hover = hit
        redraw
      end

      # Status bar ENTER button / Keys > Auto Enter: press Enter over and over,
      # a pause after each answer, until switched off.
      def set_auto_enter(on)
        @controller.auto_enter = on
        sync_menu_checks
        redraw
      end

      def redraw = @area&.redraw

      # The menus are drawn in our own title bar (Windows).
      def custom_title? = @title_bar&.installed? || false

      def menu_bar_hidden? = (@menu_bar&.usable? && (custom_title? || @config["hide_menu_bar"])) || false

      # Menu bar hidden and no title bar menus: show the ☰ button in the status bar.
      def compact_menu? = menu_bar_hidden? && !custom_title?

      def title_h = custom_title? ? TITLE_H : 0

      # Height above the screen: the title bar (which holds the tabs), or
      # without it the row of tabs.
      def strip_h = custom_title? ? 0 : TAB_STRIP_H
      def header_h = title_h + strip_h

      def grid_size
        scr = @controller.snapshot
        scr ? [scr.rows, scr.cols] : [@controller.rows, @controller.cols]
      end

      # ---- window --------------------------------------------------------------

      def build_window
        @window = Ui.window("ruby3270", 1400, 860, menubar: true, margined: false)
        UI.window_on_closing(@window) do
          close_child_windows
          @program.window_closed(self)
          1
        end

        box = Ui.vbox(padded: false)
        @area = Ui::Area.new(draw: ->(p) { draw(p) }, mouse: ->(e) { mouse(e) },
                             key: ->(e) { key(e) }, crossed: lambda { |_left|
                               title_hover(nil)
                               @tab_hover = nil
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
        top = header_h + 4 + SCREEN_PAD
        fit_grid(rows, cols, SCREEN_PAD, top, width - panel_w - (2 * SCREEN_PAD),
                 height - top - STATUS_H - 4 - SCREEN_PAD, @config["font"], top: true)
      end

      # Background while the keyboard is locked by an error (X -f), until Reset.
      LOCKED_BACKGROUND = [0x2E, 0x0C, 0x10].freeze

      def error_locked?
        st = @controller.snapshot&.status
        return false unless st&.connected?

        st.error? || @controller.operator_error?
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
        pt.fill_rect(0, 0, w, h, error_locked? ? LOCKED_BACKGROUND : BACKGROUND)
        custom_title? ? draw_title_bar(w) : draw_strip_row(w)

        size, cw, ch, ox, oy = metrics(w, h)
        scr = @controller.snapshot
        font = @config["font"]

        if scr
          draw_crosshair(scr, cw, ch, ox, oy) if @config["crosshair"] && scr.status&.connected?
          paint_cells(pt, scr, size, cw, ch, ox, oy, font, underline: @config["underline_input_fields"])
          draw_misspellings(scr, cw, ch, ox, oy)
          draw_find_matches(scr, cw, ch, ox, oy)
          draw_cursor(scr, cw, ch, ox, oy) if scr.status&.connected?
          draw_selection(cw, ch, ox, oy)
          # Dim the last screen once the session has ended.
          pt.fill_rect(ox, oy, cw * scr.cols, ch * scr.rows, BACKGROUND, 0.6) unless scr.status&.connected?
        end
        draw_start_page(w) if start_page?
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
        draw_tabs(x + 8, buttons_x - CAPTION_MIN, 0, TITLE_H)

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
        tab_hover_at(event)
        start_hover_at(event)
        title_hover(tab_hit(event) ? nil : title_hit(event)) if custom_title?
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
           "Click to #{@controller.connected? || @controller.connecting? ? 'disconnect' : 'connect'}.",
           ("Scripts can attach to this session on port #{@controller.attach_port}." if @controller.attach_port)].compact
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

      def keys_label(action) = Keymap.keys_for(bindings, action).first || "(unbound)"

      # The window title (taskbar) is the shown tab's saved session name, never
      # the host address.
      def update_title(scr)
        name = @tab && (@tab.custom_title || (@tab.name && @tab.title)) # as the tab shows it: "PROD (2)"
        live = scr&.status&.connected? || @controller.connecting?
        title = @tab&.custom_title || (live && name) || "ruby3270"
        return if @title == title

        @title = title
        UI.window_set_title(@window, title)
      end

      # ---- keyboard ------------------------------------------------------------

      def key(event)
        return tab_edit_key(event) if @tab_edit
        return picker_key(event) if @picker
        return true if @snip_focus && panel_key(event)

        tap = @tap.feed(event)
        return perform(Keymap.action_result(bindings[tap])) if tap && bindings[tap]

        action = Keymap.translate(event, bindings)
        return false unless action

        perform(action)
      end

      def perform(action)
        case action[0]
        when :history then show_history
        when :find then show_find
        when :crosshair then @program.for_all(:set_crosshair, !@config["crosshair"])
        when :caps then @program.for_all(:set_caps, !@config["caps"])
        when :snippet_picker then open_picker
        when :snippet_bar then @program.for_all(:toggle_snippet_bar, !snippet_bar_shown?)
        when :new_tab then new_tab
        when :close_tab then close_tab
        when :new_window then new_window
        when :next_tab then next_tab
        when :prev_tab then prev_tab
        when :spell_next then spell_next
        when :snippet then run_snippet_number(action[1])
        when :copy then copy
        when :paste then paste
        when :key
          clear_selection
          @controller.press(action[1])
        when :type
          return true if start_page? && start_page_number(action[1])

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
        elsif event[:down] == 2 then middle_click(event)
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
        hit = tab_hit(event)
        return tab_mouse_down(event, hit) if hit

        finish_tab_edit # a click anywhere else keeps the new name

        hit = start_page? && hit_at(@start_hits, event)
        return start_page_click(hit) if hit

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
      # where the pointer is. Without a selection, on a misspelled word: its
      # suggestions menu. Otherwise nothing happens.
      def right_click(event)
        if (hit = tab_hit(event)) && hit[0] != :new_tab
          tab = @tabs[hit[1]]
          return UI.queue_main { tab_menu(tab) }
        end
        return unless @controller.snapshot
        return spell_click(event) unless @selection

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
        return @tab_down = false if @tab_down
        return tab_mouse_up(event) if @tab_pressed
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
            when :caps then @program.for_all(:set_caps, !@config["caps"])
            when :fk then @program.for_all(:toggle_keybar, !keybar_shown?)
            when :auto_enter then set_auto_enter(!@controller.auto_enter?)
            when :snip then @program.for_all(:toggle_snippet_bar, !snippet_bar_shown?)
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
        @program.sync_check(:key_bar, on)
        set_option("key_bar", on)
        @reshape = true
        redraw
      end

      # ---- window shape ----------------------------------------------------------

      # Height of the parts of the drawing area that aren't the screen grid
      # (title bar, margins, status bar), in drawing units.
      def chrome_h = header_h + 4 + STATUS_H + 4 + (2 * SCREEN_PAD)

      # Width beside the screen: the snippets sidebar and the margins.
      def side_w = panel_w + (2 * SCREEN_PAD)

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
        ((width - extra_w - (side_w * scale)) / grid_ratio) + (chrome_h * scale) + extra_h
      end

      def shaped_width(height, extras)
        extra_w, extra_h, scale = extras
        ((height - extra_h - (chrome_h * scale)) * grid_ratio) + extra_w + (side_w * scale)
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

      # Snaps the window to the screen's shape (not when maximized). Normally the
      # width stays and the height follows; keep: :height (the snippets sidebar
      # opening or closing) keeps the height and grows or shrinks the width, so
      # the screen itself doesn't change size.
      def fit_window_to_screen(keep: :width)
        @shaped_for = grid_size
        return unless @config["lock_ratio"] && Win32.available? && !Win32.maximized?(@window)
        return unless (extras = window_extras)

        width, height = Win32.window_size(@window)
        if keep == :height
          width = shaped_width(height, extras)
        else
          height = shaped_height(width, extras)
        end
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
        @program.sync_check(:caps, on)
        redraw
      end

      def set_crosshair(on)
        set_option("crosshair", on)
        @program.sync_check(:crosshair, on)
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

      # Session > Edit Session: the connections dialog, open on this tab's
      # session. Save keeps the changes (the tab follows a new name); Connect
      # reconnects this tab with them.
      def edit_session
        tab = @tab
        target = tab&.controller&.last_target
        return connections_dialog unless target

        @connections = ConnectionsDialog.new(
          @config, select: target, title: "Edit Session",
                   on_connect: lambda { |conn|
                     next open_session(conn) unless @tabs.include?(tab)

                     select_tab(tab)
                     connect_to(conn)
                   },
                   on_save: lambda {
                     (conn = @connections.opened) && @tabs.include?(tab) && tab.controller.retarget(conn)
                     @program.for_all(:redraw) # tabs and the window title show the new name
                   }
        )
        @connections.show
      end

      def connections_dialog
        @connections = ConnectionsDialog.new(@config, on_connect: ->(conn) { open_session(conn) },
                                                      on_save: -> { @program.for_all(:redraw) }) # new tab pages list them
        @connections.show
      end

      # ---- Session > Export / Import Settings --------------------------------------

      def personal_snippets
        library.reload_if_changed
        library.items.select { |i| i.file == library.personal_file }
      end

      def export_settings
        path = Ui.take_text(UI.save_file(@window))
        return if path.empty?

        path += ".yml" unless path.match?(/\.ya?ml\z/i)
        bundle = SettingsTransfer.export(@config, personal_snippets)
        SettingsTransfer.write(path, bundle)
        msg_box("Export Settings", "Saved #{SettingsTransfer.summary(SettingsTransfer.read(path))} to\n#{path}\n\n" \
                                   "Import it with Session > Import Settings on the other computer.")
      rescue SystemCallError => e
        msg_box("Export Settings", "Couldn't save the file:\n#{e.message}")
      end

      def import_settings
        path = Ui.open_file(@window)
        return unless path

        bundle = SettingsTransfer.read(path)
        question = "Import #{SettingsTransfer.summary(bundle)} from #{File.basename(path)}?\n\n" \
                   "Sessions and snippets with the same name are replaced; your others are kept. " \
                   "The file's options replace yours."
        return unless !Win32.available? || Win32.confirm(@window, "Import Settings", question)

        snippets = SettingsTransfer.apply(bundle, @config)
        @config.save
        merge_snippets(snippets)
        @program.reload_bindings
        @program.for_all(:redraw)
        msg_box("Import Settings", "Imported. Some options (view and menu settings) show after you restart ruby3270.")
      rescue ArgumentError, Psych::Exception, SystemCallError => e
        msg_box("Import Settings", "Couldn't import #{File.basename(path.to_s)}:\n#{e.message}")
      end

      def merge_snippets(snippets)
        SettingsTransfer.merge_snippets(library, snippets)
        snippets_changed
      end

      # ---- opening saved sessions ------------------------------------------------

      public

      # bin/tn3270 --session NAME (or another launch handing over its
      # session) opens that saved session; a name that isn't saved is tried
      # as host:port. {"host" => "host:port"} opens a host.
      def open_request(request)
        if (name = request["session"])
          conn = @config.connections.find { |c| c["name"].to_s.casecmp?(name.strip) }
          open_session(conn || name)
        elsif (host = request["host"])
          open_session(host)
        end
      end

      private

      # Opens a session in this tab if it isn't in use, otherwise in a new
      # tab: a live session is never replaced.
      def open_session(target)
        new_tab unless @tab.idle?
        saved = target.is_a?(Hash) && @config.connections.include?(target)
        saved ? connect_to(target) : @controller.connect(target)
      end

      # Connects this tab to a saved connection and moves it to the top of the
      # new tab page's list.
      def connect_to(conn)
        name = conn["name"].to_s
        @config["last_connection"] = name
        @config["recent"] = ([name] + Array(@config["recent"]) - [""]).uniq.first(50)
        @config.save
        @controller.connect(conn)
      end

      # Saved connections, most recently used first.
      def recent_connections
        order = Array(@config["recent"])
        @config.connections.each_with_index
               .sort_by { |c, i| [order.index(c["name"]) || order.size, i] }
               .map(&:first)
      end

      def keys_dialog
        @keys = KeysDialog.new(@config, on_change: -> { @program.reload_bindings })
        @keys.show
      end

      def font_dialog
        @font = FontDialog.new(@config, on_change: -> { @program.for_all(:font_changed) })
        @font.show
      end

      def font_changed
        @reshape = true
        redraw
      end

      def keyboard_help
        msg_box("Keyboard", Keymap.help(bindings))
      end
    end
  end
end
