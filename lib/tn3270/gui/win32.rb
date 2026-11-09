# frozen_string_literal: true

require "fiddle"
require_relative "config"

module Tn3270
  module Gui
    # Windows-only touches libui has no API for: the window icon, and hiding
    # the menu bar while still opening the same menus from a button. Every
    # method is a no-op (returns nil) on other platforms or if a call fails.
    module Win32
      ICON = File.expand_path("../../../assets/tn3270.ico", __dir__)

      WM_SETICON = 0x0080
      WM_NULL = 0
      IMAGE_ICON = 1
      LR_LOADFROMFILE = 0x10
      SM_CXICON = 11
      SM_CXSMICON = 49
      MF_BYPOSITION = 0x400
      MF_POPUP = 0x10
      TPM_LEFTALIGN = 0x0
      TPM_BOTTOMALIGN = 0x20
      SWP_FRAMECHANGED = 0x20
      SWP_NOMOVE_SIZE_Z = 0x1 | 0x2 | 0x4 # NOSIZE | NOMOVE | NOZORDER

      module_function

      def available? = Config::WINDOWS && !user32.nil?

      def user32
        return @user32 if defined?(@user32)

        @user32 = Config::WINDOWS ? Fiddle.dlopen("user32") : nil
      rescue Fiddle::DLError
        @user32 = nil
      end

      def fn(name, args, ret = Fiddle::TYPE_INT)
        @fns ||= {}
        @fns[name] ||= Fiddle::Function.new(user32[name], args, ret)
      end

      P = Fiddle::TYPE_VOIDP
      I = Fiddle::TYPE_INT
      U = Fiddle::TYPE_UINTPTR_T

      def wide(str) = Fiddle::Pointer["#{str}\0".encode("UTF-16LE")]

      # An OK / Cancel question with a "?" icon. True for OK.
      def confirm(window, title, text)
        fn("MessageBoxW", [P, P, P, I]).call(hwnd(window), wide(text), wide(title), 0x1 | 0x20) == 1 # MB_OKCANCEL | MB_ICONQUESTION
      end

      # HWND of a libui control (a window or any widget pointer).
      def hwnd(control) = ::LibUI.control_handle(control)

      # A point in a control's client area -> screen coordinates.
      def client_to_screen(control, x, y)
        ptr = Fiddle::Pointer[[x.round, y.round].pack("l2")]
        fn("ClientToScreen", [P, P]).call(hwnd(control), ptr)
        ptr[0, 8].unpack("l2")
      end

      CHOICE_SEPARATOR = 0x800 # MF_SEPARATOR
      CHOICE_GRAYED = 0x1      # MF_GRAYED
      TPM_NONOTIFY = 0x80
      TPM_RETURNCMD = 0x100

      # A popup menu that returns the chosen item's index (nil: none chosen).
      # items: labels; nil for a separator; [label, false] for a greyed-out
      # item. Opens at screen point `at`, or at the mouse pointer. Blocks
      # until the menu closes.
      def choose(control, items, at: nil)
        return nil unless available?

        menu = fn("CreatePopupMenu", [], P).call
        append = fn("AppendMenuW", [P, I, U, P])
        items.each_with_index do |item, i|
          if item.nil?
            append.call(menu, CHOICE_SEPARATOR, 0, nil)
          else
            label, enabled = Array(item)
            append.call(menu, enabled == false ? CHOICE_GRAYED : 0, i + 1, wide(label.gsub("&", "&&")))
          end
        end
        unless at
          pt = Fiddle::Pointer.malloc(8)
          fn("GetCursorPos", [P]).call(pt)
          at = pt[0, 8].unpack("l2")
        end
        win = hwnd(control)
        fn("ReleaseCapture", []).call
        fn("SetForegroundWindow", [P]).call(win)
        id = fn("TrackPopupMenu", [P, I, I, I, I, P, P]).call(menu, TPM_RETURNCMD | TPM_NONOTIFY, at[0], at[1], 0, win, nil)
        fn("PostMessageW", [P, I, U, P]).call(win, WM_NULL, 0, nil)
        id.positive? ? id - 1 : nil
      ensure
        fn("DestroyMenu", [P]).call(menu) if menu
      end

      # Sets the title bar / taskbar icon of a window.
      def set_icon(window)
        return unless available? && File.exist?(ICON)

        h = hwnd(window)
        load = fn("LoadImageW", [P, P, I, I, I, I], P)
        metric = fn("GetSystemMetrics", [I])
        send = fn("SendMessageW", [P, I, U, P], Fiddle::TYPE_INTPTR_T)
        [[0, SM_CXSMICON], [1, SM_CXICON]].each do |which, sm|
          size = metric.call(sm)
          icon = load.call(nil, wide(ICON), IMAGE_ICON, size, size, LR_LOADFROMFILE)
          send.call(h, WM_SETICON, which, icon) unless icon.null?
        end
        true
      rescue StandardError
        nil
      end

      # Left and right virtual-key codes for each modifier.
      SIDES = { control: [0xA2, 0xA3], alt: [0xA4, 0xA5], shift: [0xA0, 0xA1] }.freeze

      # Which physical modifier key is down right now: :left, :right or nil.
      def modifier_side(mod)
        return nil unless available? && SIDES[mod]

        state = fn("GetKeyState", [I], Fiddle::TYPE_SHORT)
        left, right = SIDES[mod]
        if state.call(right).negative? then :right
        elsif state.call(left).negative? then :left
        end
      rescue StandardError
        nil
      end

      # Whether the keyboard's own Caps Lock is on.
      def caps_lock_on?
        return false unless available?

        fn("GetKeyState", [I], Fiddle::TYPE_SHORT).call(0x14).odd?
      rescue StandardError
        false
      end

      # Gives keyboard focus to a control (e.g. an area that captures keys).
      def focus_control(control)
        return unless available?

        fn("SetFocus", [P], P).call(::LibUI.control_handle(control))
      rescue StandardError
        nil
      end

      # Sets a table's column widths in pixels; -2 fills the remaining space.
      LVM_SETCOLUMNWIDTH = 0x101E
      def set_column_widths(table, widths)
        return unless available?

        h = ::LibUI.control_handle(table)
        # LibUI wraps the list view in a container on some versions; use the child if so.
        child = fn("FindWindowExW", [P, P, P, P], P).call(h, nil, wide("SysListView32"), nil)
        h = child unless child.null?
        widths.each_with_index do |w, i|
          fn("SendMessageW", [P, I, U, P], Fiddle::TYPE_INTPTR_T).call(h, LVM_SETCOLUMNWIDTH, i, Fiddle::Pointer.new(w & 0xFFFFFFFF))
        end
      rescue StandardError
        nil
      end

      # Brings a window to the front.
      def focus(window)
        return unless available?

        fn("SetForegroundWindow", [P]).call(hwnd(window))
      rescue StandardError
        nil
      end

      # Outer size of a window, borders and menu bar included: [w, h].
      def window_size(control)
        rect = Fiddle::Pointer.malloc(16, Fiddle::RUBY_FREE)
        fn("GetWindowRect", [P, P]).call(hwnd(control), rect)
        l, t, r, b = rect[0, 16].unpack("l4")
        [r - l, b - t]
      end

      # Inside size of a control in pixels: [w, h].
      def client_size(control)
        rect = Fiddle::Pointer.malloc(16, Fiddle::RUBY_FREE)
        fn("GetClientRect", [P, P]).call(hwnd(control), rect)
        _, _, r, b = rect[0, 16].unpack("l4")
        [r, b]
      end

      def maximized?(window) = fn("IsZoomed", [P]).call(hwnd(window)) != 0

      # The largest outer size Windows lets a window be dragged to: [w, h].
      SM_CXMAXTRACK = 59
      SM_CYMAXTRACK = 60
      def max_window_size
        metric = fn("GetSystemMetrics", [I])
        [metric.call(SM_CXMAXTRACK), metric.call(SM_CYMAXTRACK)]
      end

      # The usable part of the monitor a window is on (screen minus taskbar):
      # [left, top, width, height].
      def work_area(window)
        monitor = fn("MonitorFromWindow", [P, I], P).call(hwnd(window), 2) # MONITOR_DEFAULTTONEAREST
        info = Fiddle::Pointer.malloc(40, Fiddle::RUBY_FREE)
        info[0, 4] = [40].pack("l") # cbSize
        fn("GetMonitorInfoW", [P, P]).call(monitor, info)
        l, t, r, b = info[20, 16].unpack("l4") # rcWork
        [l, t, r - l, b - t]
      end

      # Where a window is: [left, top].
      def window_position(control)
        rect = Fiddle::Pointer.malloc(16, Fiddle::RUBY_FREE)
        fn("GetWindowRect", [P, P]).call(hwnd(control), rect)
        rect[0, 8].unpack("l2")
      end

      # Moves and sizes a window.
      SWP_NOZ_ACTIVATE = 0x4 | 0x10 # NOZORDER | NOACTIVATE
      def place(window, left, top, width, height)
        fn("SetWindowPos", [P, P, I, I, I, I, I]).call(hwnd(window), nil, left.round, top.round, width.round, height.round, SWP_NOZ_ACTIVATE)
      end

      # Changes a window's outer size, keeping its position.
      SWP_NOMOVE_Z_ACTIVATE = 0x2 | 0x4 | 0x10 # NOMOVE | NOZORDER | NOACTIVATE
      def resize(window, width, height)
        fn("SetWindowPos", [P, P, I, I, I, I, I]).call(hwnd(window), nil, 0, 0, width.round, height.round, SWP_NOMOVE_Z_ACTIVATE)
      end

      # Moves a window, keeping its size.
      SWP_NOSIZE_Z_ACTIVATE = 0x1 | 0x4 | 0x10 # NOSIZE | NOZORDER | NOACTIVATE
      def move(window, left, top)
        fn("SetWindowPos", [P, P, I, I, I, I, I]).call(hwnd(window), nil, left.round, top.round, 0, 0, SWP_NOSIZE_Z_ACTIVATE)
      end

      # A window's outer rectangle: [left, top, right, bottom].
      def window_rect(control)
        rect = Fiddle::Pointer.malloc(16, Fiddle::RUBY_FREE)
        fn("GetWindowRect", [P, P]).call(hwnd(control), rect)
        rect[0, 16].unpack("l4")
      end

      # The mouse pointer in screen pixels: [x, y].
      def cursor_pos
        pt = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
        fn("GetCursorPos", [P]).call(pt)
        pt[0, 8].unpack("l2")
      end

      # Whether the primary mouse button is held down right now (even when the
      # pointer is outside every window of the app).
      SM_SWAPBUTTON = 23
      def primary_button_down?
        vk = fn("GetSystemMetrics", [I]).call(SM_SWAPBUTTON).zero? ? 0x01 : 0x02
        fn("GetAsyncKeyState", [I], Fiddle::TYPE_SHORT).call(vk).negative?
      end

      # The window that has the keyboard (a raw HWND as an integer).
      def foreground = fn("GetForegroundWindow", [], P).call.to_i

      # Shows a window (restoring it if minimized) and brings it to the front.
      def bring_to_front(window)
        h = hwnd(window)
        fn("ShowWindow", [P, I]).call(h, 9) if fn("IsIconic", [P]).call(h) != 0 # SW_RESTORE
        fn("SetForegroundWindow", [P]).call(h)
      rescue StandardError
        nil
      end

      # Lets the running copy of the app take the foreground when this one
      # hands it a session (Windows only allows that if we say so).
      def allow_foreground
        return unless available?

        fn("AllowSetForegroundWindow", [I]).call(-1) # ASFW_ANY
      rescue StandardError
        nil
      end

      # Lets the app reshape a window while the user drags its edges. The
      # block gets the edge being dragged (WMSZ_* 1-8) and the proposed outer
      # rectangle [left, top, right, bottom]; it returns a new rectangle, or
      # nil to leave it alone.
      class Sizing
        WM_SIZING = 0x214
        SUBCLASS_ID = 0x3271
        LP = Fiddle::TYPE_INTPTR_T

        def initialize(window, &adjust)
          @hwnd = Win32.hwnd(window)
          @adjust = adjust
          comctl = Fiddle.dlopen("comctl32")
          @def_proc = Fiddle::Function.new(comctl["DefSubclassProc"], [U, I, U, LP], LP)
          # Kept in an instance variable so it is never garbage collected.
          @proc = Fiddle::Closure::BlockCaller.new(LP, [U, I, U, LP, U, U]) do |hwnd, msg, wp, lp, _id, _ref|
            msg == WM_SIZING && sizing(wp, lp) ? 1 : @def_proc.call(hwnd, msg, wp, lp)
          end
          Fiddle::Function.new(comctl["SetWindowSubclass"], [U, P, U, U], I).call(@hwnd.to_i, @proc, SUBCLASS_ID, 0)
        end

        private

        def sizing(edge, lp)
          ptr = Fiddle::Pointer.new(lp)
          rect = @adjust.call(edge, ptr[0, 16].unpack("l4"))
          return false unless rect

          ptr[0, 16] = rect.map(&:round).pack("l4")
          true
        rescue StandardError
          false
        end
      end

      # Keeps hold of the window's menu bar so it can be hidden and shown.
      class MenuBar
        def initialize(window)
          @hwnd = Win32.hwnd(window)
          @bar = Win32.fn("GetMenu", [P], P).call(@hwnd)
          @popup = nil
        end

        def usable? = !@bar.null?

        def visible=(show)
          return unless usable?

          Win32.fn("SetMenu", [P, P]).call(@hwnd, show ? @bar : nil)
          # Make Windows re-measure the frame so the content area resizes.
          Win32.fn("SetWindowPos", [P, P, I, I, I, I, I]).call(@hwnd, nil, 0, 0, 0, 0, SWP_FRAMECHANGED | SWP_NOMOVE_SIZE_Z)
        end

        # Opens the menus as one popup at the mouse pointer. Choosing an item
        # sends the same command the menu bar would, so LibUI runs its handler.
        def popup
          return unless usable?

          pt = Fiddle::Pointer.malloc(8)
          Win32.fn("GetCursorPos", [P]).call(pt)
          x, y = pt[0, 8].unpack("l2")
          Win32.fn("SetForegroundWindow", [P]).call(@hwnd)
          Win32.fn("TrackPopupMenu", [P, I, I, I, I, P, P]).call(popup_menu, TPM_LEFTALIGN | TPM_BOTTOMALIGN, x, y, 0, @hwnd, nil)
          Win32.fn("PostMessageW", [P, I, U, P]).call(@hwnd, WM_NULL, 0, nil)
        end

        # Top-level menu names ("Session", "Edit", ...).
        def names
          return [] unless usable?

          @names ||= Array.new(Win32.fn("GetMenuItemCount", [P]).call(@bar)) do |i|
            buf = Fiddle::Pointer.malloc(256)
            len = Win32.fn("GetMenuStringW", [P, I, P, I, I]).call(@bar, i, buf, 127, MF_BYPOSITION)
            buf[0, len * 2].force_encoding("UTF-16LE").encode("UTF-8").delete("&")
          end
        end

        MF_STRING = 0x0
        MF_GRAYED = 0x1
        MF_BYCOMMAND = 0x0

        # Remembers the command IDs of `count` placeholder items starting at
        # `first` in top-level menu `menu_index`, so their text can be changed
        # later with set_slots. LibUI still runs each slot's handler.
        def reserve_slots(menu_index, first, count)
          return unless usable?

          @slot_menu = Win32.fn("GetSubMenu", [P, I], P).call(@bar, menu_index)
          @slot_first = first
          @slot_ids = Array.new(count) { |i| Win32.fn("GetMenuItemID", [P, I]).call(@slot_menu, first + i) }
        end

        # Shows one slot per label (the rest are removed). An empty list shows
        # `empty` as a greyed-out item.
        def set_slots(labels, empty:)
          return unless @slot_ids

          remove = Win32.fn("RemoveMenu", [P, I, I])
          insert = Win32.fn("InsertMenuW", [P, I, I, U, P])
          @slot_ids.each { |id| remove.call(@slot_menu, id, MF_BYCOMMAND) }
          shown = labels.first(@slot_ids.size)
          if shown.empty?
            insert.call(@slot_menu, @slot_first, MF_BYPOSITION | MF_STRING | MF_GRAYED, @slot_ids[0], Win32.wide(empty))
          else
            shown.each_with_index do |text, i|
              insert.call(@slot_menu, @slot_first + i, MF_BYPOSITION | MF_STRING, @slot_ids[i], Win32.wide(text))
            end
          end
          Win32.fn("DrawMenuBar", [P]).call(@hwnd)
        end

        # Opens one top-level menu with its top-left corner at a screen point.
        # Blocks until the menu closes.
        def popup_submenu(index, x, y)
          return unless usable?

          sub = Win32.fn("GetSubMenu", [P, I], P).call(@bar, index)
          Win32.fn("ReleaseCapture", []).call
          Win32.fn("SetForegroundWindow", [P]).call(@hwnd)
          Win32.fn("TrackPopupMenu", [P, I, I, I, I, P, P]).call(sub, TPM_LEFTALIGN, x, y, 0, @hwnd, nil)
          Win32.fn("PostMessageW", [P, I, U, P]).call(@hwnd, WM_NULL, 0, nil)
        end

        private

        # A popup whose entries are the menu bar's own submenus (shared, so
        # check marks stay in sync).
        def popup_menu
          @popup ||= begin
            menu = Win32.fn("CreatePopupMenu", [], P).call
            names.each_with_index do |name, i|
              sub = Win32.fn("GetSubMenu", [P, I], P).call(@bar, i)
              Win32.fn("AppendMenuW", [P, I, U, P]).call(menu, MF_POPUP, sub.to_i, Win32.wide(name))
            end
            menu
          end
        end
      end

      # A VS Code style window: the native title bar is removed so the app can
      # draw its own (icon, menus, title, window buttons) in the top of the
      # content area. Windows keeps the shadow and the side/bottom resize
      # edges; dragging, double-click maximize and edge snapping go through
      # the normal Windows code paths.
      class TitleBar
        WM_NCCALCSIZE = 0x83
        WM_NCLBUTTONDOWN = 0xA1
        WM_SYSCOMMAND = 0x112
        WM_CLOSE = 0x10
        SC_MINIMIZE = 0xF020
        SC_MAXIMIZE = 0xF030
        SC_RESTORE = 0xF120
        HIT = { caption: 2, top: 12, top_left: 13, top_right: 14 }.freeze
        SM_CYFRAME = 33
        SM_CXPADDEDBORDER = 92
        SUBCLASS_ID = 0x3270

        def initialize(window)
          @window = window
          @hwnd = Win32.hwnd(window)
          @comctl = Fiddle.dlopen("comctl32")
          @def_proc = Fiddle::Function.new(@comctl["DefSubclassProc"], [U, I, U, Fiddle::TYPE_INTPTR_T], Fiddle::TYPE_INTPTR_T)
          @installed = false
        end

        def installed? = @installed

        # Removes the native title bar. Returns true on success.
        def install
          return true if @installed

          # Kept in an instance variable so it is never garbage collected.
          @proc ||= Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_INTPTR_T, [U, I, U, Fiddle::TYPE_INTPTR_T, U, U]) do |hwnd, msg, wp, lp, _id, _ref|
            msg == WM_NCCALCSIZE && wp != 0 ? calc_size(hwnd, msg, wp, lp) : @def_proc.call(hwnd, msg, wp, lp)
          end
          set = Fiddle::Function.new(@comctl["SetWindowSubclass"], [U, P, U, U], I)
          @installed = set.call(@hwnd.to_i, @proc, SUBCLASS_ID, 0) != 0
          frame_changed
          @installed
        rescue StandardError
          false
        end

        # Brings the native title bar back.
        def uninstall
          return unless @installed

          remove = Fiddle::Function.new(@comctl["RemoveWindowSubclass"], [U, P, U], I)
          remove.call(@hwnd.to_i, @proc, SUBCLASS_ID)
          @installed = false
          frame_changed
        end

        def maximized? = Win32.fn("IsZoomed", [P]).call(@hwnd) != 0

        def minimize = syscommand(SC_MINIMIZE)
        def toggle_maximize = syscommand(maximized? ? SC_RESTORE : SC_MAXIMIZE)
        def close = Win32.fn("PostMessageW", [P, I, U, P]).call(@hwnd, WM_CLOSE, 0, nil)

        # Hands a mouse press over to Windows as if it were on the title bar
        # (:caption, to move the window) or on the top border (to resize).
        def begin_drag(area = :caption)
          pt = Fiddle::Pointer.malloc(8)
          Win32.fn("GetCursorPos", [P]).call(pt)
          x, y = pt[0, 8].unpack("l2")
          Win32.fn("ReleaseCapture", []).call
          lparam = ((y & 0xFFFF) << 16) | (x & 0xFFFF)
          Win32.fn("SendMessageW", [P, I, U, U], Fiddle::TYPE_INTPTR_T).call(@hwnd, WM_NCLBUTTONDOWN, HIT.fetch(area), lparam)
        end

        # Converts a point in a control (e.g. the drawing area) to screen pixels.
        def to_screen(control, x, y)
          pt = [x.round, y.round].pack("l2")
          ptr = Fiddle::Pointer[pt]
          Win32.fn("ClientToScreen", [P, P]).call(::LibUI.control_handle(control), ptr)
          ptr[0, 8].unpack("l2")
        end

        private

        def syscommand(cmd)
          Win32.fn("PostMessageW", [P, I, U, P]).call(@hwnd, WM_SYSCOMMAND, cmd, nil)
        end

        def frame_changed
          Win32.fn("SetWindowPos", [P, P, I, I, I, I, I]).call(@hwnd, nil, 0, 0, 0, 0, SWP_FRAMECHANGED | SWP_NOMOVE_SIZE_Z)
        end

        # Let Windows size the frame, then give the caption area back to the
        # client. A maximized window hangs over the screen edge by the frame
        # width, so keep that much at the top.
        def calc_size(hwnd, msg, wp, lp)
          ptr = Fiddle::Pointer.new(lp)
          top = ptr[0, 16].unpack("l4")[1]
          result = @def_proc.call(hwnd, msg, wp, lp)
          rect = ptr[0, 16].unpack("l4")
          inset = 0
          if Win32.fn("IsZoomed", [U]).call(hwnd) != 0
            metric = Win32.fn("GetSystemMetrics", [I])
            inset = metric.call(SM_CYFRAME) + metric.call(SM_CXPADDEDBORDER)
          end
          rect[1] = top + inset
          ptr[0, 16] = rect.pack("l4")
          result
        end
      end
    end
  end
end
