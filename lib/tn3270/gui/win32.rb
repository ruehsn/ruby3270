# frozen_string_literal: true

require "fiddle"
require_relative "config"

module Tn3270
  module Gui
    # Windows-only touches LibUI has no API for: the window icon, and hiding
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

      # HWND of a Glimmer window proxy.
      def hwnd(window) = ::LibUI.control_handle(window.libui)

      # Sets the title bar / taskbar icon of a Glimmer window.
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

        fn("SetFocus", [P], P).call(::LibUI.control_handle(control.libui))
      rescue StandardError
        nil
      end

      # Sets a table's column widths in pixels; -2 fills the remaining space.
      LVM_SETCOLUMNWIDTH = 0x101E
      def set_column_widths(table, widths)
        return unless available?

        h = ::LibUI.control_handle(table.libui)
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
          Win32.fn("ClientToScreen", [P, P]).call(::LibUI.control_handle(control.libui), ptr)
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
