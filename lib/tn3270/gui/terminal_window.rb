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
require_relative "theme"
require_relative "hit_map"
require_relative "tab_strip_view"
require_relative "start_page"
require_relative "status_bar"
require_relative "title_bar_view"
require_relative "window_shape"
require_relative "find_ui"
require_relative "screenshot"
require_relative "settings_transfer"

module Tn3270
  module Gui
    # One desktop window: a strip of session tabs, the active tab's screen
    # (it scales with the window), an optional PF key bar, and a status bar
    # with a menu button and a connect button. Program owns the windows and
    # the menus they share; each Tab owns its connection.
    #
    # This file is the window itself: building it, the draw / key / mouse
    # handlers, and its commands. The parts it draws are modules of their own:
    # TabStripView, StartPage, TitleBarView, StatusBar, SnippetPanel, SpellUi,
    # FindUi and WindowShape.
    class TerminalWindow
      include Theme
      include ScreenPainter
      include TabStripView
      include StartPage
      include TitleBarView
      include StatusBar
      include SnippetPanel
      include SpellUi
      include FindUi
      include WindowShape

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
        @status_hits = @tab_hits = @start_hits = @title_hits = @snip_hits = @picker_hits = HitMap.new # until drawn
        @tabs.each { |t| t.controller.background = !t.equal?(@tab) }
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
          relabel_menus(@program.menu_texts) # shortcuts, in case the keys changed since the menus were made
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

      def relabel_menus(texts) = @menu_bar&.relabel(texts)
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

      private

      attr_reader :controller, :config

      def bindings = @program.bindings

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

      def new_window = @program.new_window

      def close_child_windows
        @history_window.close if @history_window&.open?
        @find_window.close if @find_window&.open?
      end

      def focus_screen = Win32.focus_control(@area.control)

      def sync_menu_checks
        @program.sync_check(:auto_enter, @controller.auto_enter?)
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

      def draw_selection(cw, ch, ox, oy)
        return unless @selection

        r1, r2 = [@selection[0], @selection[2]].minmax
        c1, c2 = [@selection[1], @selection[3]].minmax
        @painter.fill_rect(ox + (c1 * cw), oy + (r1 * ch), (c2 - c1 + 1) * cw, (r2 - r1 + 1) * ch, SELECTION, 0.35)
      end

      def ui_text(x, y, str, fg)
        @painter.text(x, y, FontMetrics.text_width(UI_FONT, UI_SIZE, str) + 20, str, fg, UI_FONT, UI_SIZE)
      end

      def mouse_move(event)
        tab_hover_at(event)
        start_hover_at(event)
        title_hover(tab_hit(event) ? nil : title_hit(event)) if custom_title?
        hover_status(event)
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
        when :crosshair, :caps, :snippet_bar then @program.flip(action[0], self)
        when :snippet_picker then open_picker
        when :new_tab then new_tab
        when :close_tab then close_tab
        when :new_window then new_window
        when :next_tab then next_tab
        when :prev_tab then prev_tab
        when :spell_next then spell_next
        when :snippet then run_snippet_number(action[1])
        when :copy then copy
        when :paste then paste
        when :paste_rest then paste_rest
        when :audit_copy then copy_audit_picture
        when :audit_save then save_audit_picture
        when :undo then undo
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

        hit = start_page? && @start_hits.at(event)
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
            when :caps then @program.flip(:caps, self)
            when :fk then @program.flip(:key_bar, self)
            when :auto_enter then set_auto_enter(!@controller.auto_enter?) # this tab's, not a shared setting
            when :snip then @program.flip(:snippet_bar, self)
            when :position then nil # its tooltip shows the screen size
            else toggle_connection
            end
          end
        end
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

      # The lines the last paste had no room for, at the cursor (after
      # scrolling the host's screen on, say).
      def paste_rest
        clear_selection
        @controller.paste_rest
      end

      # ---- a picture of the window, for audit ------------------------------------
      # The whole window as it is, status bar included. In the picture (only
      # there) the status bar gives the full date and time, the session and
      # who took it: see StatusBar#audit_line.

      # The picture (a Screenshot::Shot) and the time in it, or nil with a
      # message when it can't be taken.
      def audit_picture
        unless Screenshot.available?
          @controller.flash("Pictures of the window can only be taken on Windows")
          return nil
        end
        return nil unless @area_size # not drawn yet

        hide_tooltip
        @audit_stamp = Time.now
        screen_painter = @painter
        shot = Screenshot.grab(@window, @area.control, @area_size, controls: keybar_shown? ? [@keybar] : []) do |painter|
          # The window's own drawing, done again into the picture (the stamp
          # is only ever in the picture, never on the screen).
          @painter = painter
          draw(context: nil, area_width: @area_size[0], area_height: @area_size[1])
        end
        @controller.flash("The picture couldn't be taken") unless shot
        shot && [shot, @audit_stamp]
      ensure
        @painter = screen_painter if screen_painter
        @audit_stamp = nil
      end

      def copy_audit_picture
        shot, at = audit_picture
        return unless shot

        ok = Clipboard.copy_image(shot)
        @controller.flash(ok ? "Window copied as a picture, stamped #{at.strftime('%Y-%m-%d %H:%M:%S')}" : "The picture couldn't be copied")
      end

      def save_audit_picture
        return @controller.flash("Pictures of the window can only be taken on Windows") unless Screenshot.available?

        path = Ui.take_text(UI.save_file(@window))
        return if path.empty?

        path += ".png" unless path.match?(/\.png\z/i)
        shot, at = audit_picture
        return unless shot&.png

        File.binwrite(path, shot.png)
        @controller.flash("Window saved to #{File.basename(path)}, stamped #{at.strftime('%Y-%m-%d %H:%M:%S')}")
      rescue SystemCallError => e
        msg_box("Save Window as PNG", "Couldn't save the file:\n#{e.message}")
      end

      def undo
        clear_selection
        @controller.undo
      end

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

      def set_underline(on)
        set_option("underline_input_fields", on)
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
      # as host:port. {"host" => "host:port"} opens a host. Returns the tab.
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
        @tab # the tab it opened in
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

      def keys_dialog
        @keys = KeysDialog.new(@config, on_change: -> { @program.reload_bindings })
        @keys.show
      end

      def settings_dialog
        @settings = SettingsDialog.new(@program, self)
        @settings.show
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
