# frozen_string_literal: true

require_relative "ui"
require_relative "config"
require_relative "keymap"
require_relative "tab"
require_relative "instance"
require_relative "snippet_library"
require_relative "terminal_window"
require_relative "win32"

module Tn3270
  module Gui
    # The running app: its windows, the menus they share, the timer that
    # keeps them drawn, and tabs dragged from one window to another.
    #
    # libui builds one set of menus for every window; a click says which
    # window it came from, and the command runs there. View options (key bar,
    # sidebar, crosshair...) apply to every window.
    class Program
      PUMP_MS = 25 # how often the main thread checks for screen changes
      RECENT_SLOTS = 8 # saved sessions listed in the Session menu
      # Their position in the Session menu: after New Tab, New Window, Close Tab,
      # Move Tab to New Window, separator, Connections, Connect/Disconnect,
      # Allow Scripts, separator.
      RECENT_FIRST = 9
      DRAG_START = 6 # pixels the mouse moves before a press on a tab is a drag
      DETACH = 30 # pixels above or below the tab strip before a tab tears off
      CASCADE = 32 # a new window opens this far right of and below the current one

      attr_reader :config, :bindings, :windows

      def initialize(host: nil, session: nil)
        @first_run = !File.exist?(Config::PATH) && !File.exist?(Config::OLD_PATH)
        @config = Config.load
        @bindings = Keymap.bindings(@config["keys"])
        @request = { "session" => session, "host" => host }.compact
        @windows = []
        @menu = {}
        @checks = {}
        @toggles = {}
        @closing = []
        @drag = nil
      end

      def run
        if @config["single_instance"]
          Win32.allow_foreground
          return if Instance.forward(@request)

          @instance = Instance.new
        end
        # A first launch takes the team's welcome.yml, if there is one, before
        # anything reads the settings.
        @bindings = Keymap.bindings(@config["keys"]) if SettingsTransfer.welcome(@config, library, first: @first_run)
        UI.init
        start_wakeups
        build_menus
        open_window(request: @request)
        UI.timer(PUMP_MS) do
          pump
          1
        end
        UI.main
        finish
      end

      def library
        @library ||= SnippetLibrary.new(@config).tap(&:reload_if_changed)
      end

      def reload_bindings
        @bindings = Keymap.bindings(@config["keys"])
        @windows.each { |w| w.command(:redraw) }
      end

      def menu_item(name) = @menu[name]

      # Sets a check mark in the shared menus, if it changed.
      def sync_check(name, on)
        return if @checks[name] == on || !@menu[name]

        @checks[name] = on
        UI.menu_item_set_checked(@menu[name], Ui.flag(on))
      end

      # An on/off setting from the menus, for the quick picker.
      Toggle = Struct.new(:name, :label, :words, :on)

      # The settings whose label (or extra search words) has every word of `query`.
      def self.match_toggles(toggles, query)
        words = query.to_s.downcase.split
        return [] if words.empty?

        toggles.select do |t|
          hay = "#{t.label} #{t.words}".downcase
          words.all? { |w| hay.include?(w) }
        end
      end

      def toggles = @toggles.map { |name, t| Toggle.new(name, t[:label], t[:words], @checks[name] ? true : false) }
      def search_toggles(query) = Program.match_toggles(toggles, query)

      # Flips a setting as if its menu item had been clicked in `window`.
      def flip(name, window)
        t = @toggles[name] or return
        on = !@checks[name]
        @checks[name] = on
        UI.menu_item_set_checked(@menu[name], Ui.flag(on))
        t[:block].call(window, on)
      end

      # Runs a view command in every window, so they all look the same.
      def for_all(cmd, *args) = @windows.each { |w| w.command(cmd, *args) }

      # The window the user is working in.
      def active_window = (@windows.include?(@active) && @active) || @windows.last

      # ---- windows -------------------------------------------------------------------

      # Opens a window holding `tabs` (a new empty tab if none), at `rect`
      # ([left, top, width, height], outer pixels) or the default place.
      def open_window(tabs: nil, request: nil, rect: nil)
        w = TerminalWindow.new(self, tabs: tabs)
        @windows << w
        @active = w
        w.launch(rect: rect)
        w.open_request(request) if request && !request.empty?
        w
      end

      # Session > New Window: a little down and right of the current one, same size.
      def new_window
        rect = nil
        if (cur = active_window) && Win32.available?
          l, t, r, b = Win32.window_rect(cur.ui_window)
          rect = [l + CASCADE, t + CASCADE, r - l, b - t]
        end
        open_window(rect: rect)
      end

      # The user closed a window: its sessions end. The last window quits.
      def window_closed(window)
        @windows.delete(window)
        window.tabs.each { |t| retire(t) }
        UI.quit if @windows.empty?
      end

      # A closed tab: its session ends in the background, so the window
      # doesn't wait for the engine to stop.
      def retire(tab)
        @closing << Thread.new { tab.shutdown }
      end

      # Moves a tab into its own new window, a little down and right.
      def tab_to_new_window(window, tab)
        return if window.tabs.size < 2

        l, t, r, b = Win32.available? ? Win32.window_rect(window.ui_window) : [nil] * 4
        window.remove_tab(tab)
        open_window(tabs: [tab], rect: l && [l + CASCADE, t + CASCADE, r - l, b - t])
      end

      # Whether `tab` is still open in one of the windows.
      def open_tab?(tab) = @windows.any? { |w| w.tabs.include?(tab) }

      def refresh_recent_menu =@windows.each { |w| w.command(:refresh_recent_menu) }

      # ---- dragging tabs ---------------------------------------------------------------
      # A press on a tab starts a drag; from then on the timer follows the
      # mouse (it is read straight from Windows, so it works outside the
      # windows too) until the button is let go:
      #   :press - not moved far enough yet: still just a click
      #   :strip - moving along a window's tab strip: reorders the tabs
      #   :float - pulled off the strip: the tab has a window of its own that
      #            follows the mouse; over another window's tabs it joins them
      # Windows are only made and destroyed here, on the timer, never inside
      # one of their own mouse events.

      Drag = Struct.new(:tab, :window, :mode, :start, :tab_dx, :win_dx, :win_dy)

      def begin_tab_drag(window, tab)
        return unless Win32.available?

        x, y = Win32.cursor_pos
        left = window.tab_left_px(tab)
        return unless left

        _, top, = Win32.window_rect(window.ui_window)
        @drag = Drag.new(tab, window, :press, [x, y], x - left, nil, y - top)
      end

      # The tab being dragged along `window`'s strip, or nil.
      def strip_drag(window)
        d = @drag
        d && d.mode == :strip && d.window.equal?(window) ? d.tab : nil
      end

      # Whether `window` is following the mouse (then it isn't reshaped).
      def floating?(window) = @drag&.mode == :float && @drag.window.equal?(window)

      private

      def pump
        @instance&.requests&.each { |r| handle_request(r) }
        track_active
        drag_tick if @drag
        Tab.number_all(@windows.flat_map(&:tabs))
        @windows.dup.each(&:pump)
        active_window&.command(:sync_menu_checks)
      end

      # A session's screen changed (a key's answer, the host...): redraw on the
      # main thread straight away instead of on the next timer tick (25 ms,
      # which Windows rounds up to about 31). At most one wake-up is waiting
      # at a time, and the one callback is reused (UI.queue_main would keep
      # a new one alive for every call).
      def start_wakeups
        @wake_pending = false
        @wake_fn = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP]) do |_|
          @wake_pending = false
          @windows.dup.each(&:pump)
        rescue StandardError => e
          warn "#{e.class}: #{e.message}\n  #{e.backtrace.first(5).join("\n  ")}"
        end
        Tab.on_change = lambda {
          next if @wake_pending

          @wake_pending = true
          UI::FFI.uiQueueMain(@wake_fn, nil)
        }
      end

      def track_active
        return unless Win32.available?

        fg = Win32.foreground
        w = @windows.find { |win| win.hwnd_i == fg }
        @active = w if w
      end

      # Another launch of the app sent this: open its session in a tab of the
      # window in front, or (no session given) open a new window.
      def handle_request(request)
        w = request.empty? || active_window.nil? ? new_window : active_window
        w.open_request(request) unless request.empty?
        Win32.bring_to_front(w.ui_window)
      end

      def window_for(ptr)
        return active_window unless ptr

        @windows.find { |w| w.hwnd_ptr == ptr.to_i } || active_window
      end

      def drag_tick
        d = @drag
        return @drag = nil unless @windows.include?(d.window) && d.window.tabs.include?(d.tab)
        return end_drag unless Win32.primary_button_down?

        x, y = Win32.cursor_pos
        case d.mode
        when :press
          return unless (x - d.start[0]).abs > DRAG_START || (y - d.start[1]).abs > DRAG_START

          d.mode = :strip
          drag_along_strip(d, x, y)
        when :strip then drag_along_strip(d, x, y)
        when :float then drag_floating(d, x, y)
        end
      end

      def drag_along_strip(d, x, y)
        w = d.window
        strip = w.strip_rect_px
        return unless strip # not drawn yet

        wl, _, wr, = Win32.window_rect(w.ui_window)
        _, st, _, sb = strip
        if x.between?(wl, wr) && y.between?(st - DETACH, sb + DETACH)
          w.drag_tab(d.tab, x - d.tab_dx)
        else
          detach(d, x, y)
        end
      end

      # Pulled off the strip: the tab gets a window of its own, under the
      # mouse, which then follows it. A window's only tab takes the window.
      def detach(d, x, y)
        w = d.window
        w.drag_tab(d.tab, nil)
        wl, wt, wr, wb = Win32.window_rect(w.ui_window)
        if w.tabs.size > 1
          d.win_dx = (w.strip_rect_px[0] - wl) + d.tab_dx # the tab will be first in its window
          w.remove_tab(d.tab)
          d.window = open_window(tabs: [d.tab], rect: [x - d.win_dx, y - d.win_dy, wr - wl, wb - wt])
        else
          d.win_dx = x - wl
          d.win_dy = y - wt
        end
        d.mode = :float
      end

      def drag_floating(d, x, y)
        w = d.window
        Win32.move(w.ui_window, x - d.win_dx, y - d.win_dy)
        target = @windows.find { |o| !o.equal?(w) && inside?(o.strip_rect_px, x, y) }
        return unless target

        # Over another window's tabs: the tab joins them there.
        index = target.insert_index_px(x)
        w.remove_tab(d.tab)
        close_empty(w)
        target.add_tab(d.tab, index: index)
        Win32.bring_to_front(target.ui_window)
        d.window = target
        d.mode = :strip
        _, top, = Win32.window_rect(target.ui_window)
        d.win_dy = y - top
        target.drag_tab(d.tab, x - d.tab_dx)
      end

      def end_drag
        d = @drag
        @drag = nil
        return unless @windows.include?(d.window)

        d.window.drag_tab(d.tab, nil)
        return unless d.mode == :float

        Win32.bring_to_front(d.window.ui_window)
        d.window.command(:focus_screen)
      end

      # A window whose last tab was dragged away.
      def close_empty(window)
        return unless window.tabs.empty?

        @windows.delete(window)
        window.destroy
      end

      def inside?(rect, x, y)
        rect && x.between?(rect[0], rect[2]) && y.between?(rect[1], rect[3])
      end

      # After the main loop: end any session still open (whatever stopped the
      # loop), and wait for closed ones to finish, so no engine is left running.
      def finish
        Tab.on_change = nil # the main loop is over: nothing left to wake
        @instance&.close
        @windows.flat_map(&:tabs).each { |t| retire(t) }
        @windows.clear
        @closing.each { |t| t.join(5) }
      end

      # Quit (menu or the system): end every session, close every window.
      def quit_all
        tabs = @windows.flat_map(&:tabs)
        tabs.map { |t| Thread.new { t.shutdown } }.each { |t| t.join(5) }
        @windows.each(&:destroy)
        @windows.clear
      end

      # ---- menus ---------------------------------------------------------------------

      # A menu item that runs `cmd` in the window it was clicked in (or the
      # block, given that window).
      def item(menu, label, cmd = nil, *args, &block)
        it = UI.menu_append_item(menu, label)
        UI.menu_item_on_clicked(it) do |_sender, win, _data|
          w = window_for(win)
          block ? block.call(w) : w&.command(cmd, *args)
          nil
        end
        @menu[label] = it
      end

      def check_item(menu, label, checked, name = label, words: nil, &block)
        @toggles[name] = { label: label, words: words, block: block }
        it = UI.menu_append_check_item(menu, label)
        UI.menu_item_set_checked(it, Ui.flag(checked))
        @checks[name] = checked
        UI.menu_item_on_clicked(it) do |_sender, win, _data|
          on = UI.menu_item_checked(it) == 1
          @checks[name] = on
          block.call(window_for(win), on)
          nil
        end
        @menu[name] = it
      end

      def build_menus
        c = @config
        m = UI.new_menu("Session")
        item(m, "New Tab", :new_tab)
        item(m, "New Window") { new_window }
        item(m, "Duplicate Tab", :duplicate_tab)
        item(m, "Rename Tab...", :rename_tab)
        item(m, "Close Tab", :close_tab)
        item(m, "Move Tab to New Window", :tab_to_new_window)
        UI.menu_append_separator(m)
        item(m, "Connections...", :connections_dialog)
        item(m, "Connect / Disconnect", :toggle_connection)
        check_item(m, "Allow Scripts to Attach", c["allow_attach"], words: "scripting port attach api") do |_w, on|
          c["allow_attach"] = on
          c.save
          @windows.flat_map(&:tabs).each { |t| t.controller.attach_setting_changed }
        end
        UI.menu_append_separator(m)
        item(m, "Export Settings...", :export_settings)
        item(m, "Import Settings...", :import_settings)
        UI.menu_append_separator(m)
        # Placeholders for saved sessions; their text is filled in on Windows
        # (see TerminalWindow#refresh_recent_menu).
        RECENT_SLOTS.times { |i| item(m, "Session #{i + 1}", :connect_recent, i) } if Win32.available?
        # libui puts a separator before Quit by itself.
        @menu[:quit] = UI.menu_append_quit_item(m)
        UI.on_should_quit do
          quit_all
          1
        end

        m = UI.new_menu("Edit")
        item(m, "Copy (selection or screen)", :copy)
        item(m, "Copy Whole Screen", :copy_screen)
        item(m, "Paste", :paste)
        UI.menu_append_separator(m)
        item(m, "Find...", :show_find)
        UI.menu_append_separator(m)
        item(m, "Snippets: Quick Pick...", :open_picker)
        item(m, "New Snippet from Selection...", :snippet_from_selection)
        UI.menu_append_separator(m)
        check_item(m, "Caps Lock (this app only)", c["caps"], :caps, words: "uppercase capitals") { |_w, on| for_all(:set_caps, on) }

        m = UI.new_menu("Keys")
        item(m, "Keyboard Mapping...", :keys_dialog)
        seconds = (c["auto_enter_seconds"] || 2).to_f.round(1)
        check_item(m, "Auto Enter (press Enter every #{seconds}s, to watch a job)", false, :auto_enter, words: "refresh repeat") do |w, on|
          w&.command(:set_auto_enter, on)
        end
        check_item(m, "Type-Ahead (queue keys while the host is busy)", c["typeahead"], words: "typeahead queue") { |_w, on| save_option("typeahead", on) }
        check_item(m, "Numeric Fields: Digits Only", c["numeric_lock"], words: "numbers numeric lock") { |_w, on| save_option("numeric_lock", on) }
        UI.menu_append_separator(m)
        %i[pa1 pa2 pa3 clear attn sysreq reset erase_input].each do |k|
          item(m, k.to_s.upcase.tr("_", " "), :send_key, k)
        end
        UI.menu_append_separator(m)
        (13..24).each { |n| item(m, "PF#{n}", :send_key, :"pf#{n}") }

        m = UI.new_menu("View")
        item(m, "Screen History...", :show_history)
        item(m, "Font...", :font_dialog)
        UI.menu_append_separator(m)
        check_item(m, "Crosshair", c["crosshair"], :crosshair, words: "cursor ruler") { |_w, on| for_all(:set_crosshair, on) }
        check_item(m, "Key Bar (PF, Reset, Clear...)", c["key_bar"], :key_bar, words: "keybar fkeys pf keys buttons") { |_w, on| for_all(:toggle_keybar, on) }
        check_item(m, "Snippets Sidebar", c["snippet_bar"], :snippet_bar, words: "snip panel") { |_w, on| for_all(:toggle_snippet_bar, on) }
        check_item(m, "Underline Input Fields", c["underline_input_fields"], words: "fields") { |_w, on| for_all(:set_underline, on) }
        if Win32.available?
          UI.menu_append_separator(m)
          check_item(m, "Spell Check (long input fields)", c["spell_check"], words: "spelling spellcheck") { |_w, on| for_all(:set_spell_check, on) }
          item(m, "Spell Check Language...", :choose_spell_language)
          UI.menu_append_separator(m)
          check_item(m, "Lock Window Shape to the Screen", c["lock_ratio"], words: "aspect ratio resize") { |_w, on| for_all(:set_lock_ratio, on) }
        end

        m = UI.new_menu("Help")
        item(m, "Keyboard...", :keyboard_help)
        @menu[:about] = UI.menu_append_about_item(m)
        UI.menu_item_on_clicked(@menu[:about]) do |_sender, win, _data|
          window_for(win)&.command(:msg_box, "About", "ruby3270 #{Tn3270::VERSION}\nA 3270 terminal in Ruby\nEngine: s3270 (x3270 suite)")
          nil
        end
      end

      def save_option(key, on)
        @config[key] = on
        @config.save
      end
    end
  end
end
