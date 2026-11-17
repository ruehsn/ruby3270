# frozen_string_literal: true

require_relative "theme"

module Tn3270
  module Gui
    # The tab strip of a TerminalWindow: which tab is on show, opening,
    # closing, renaming and dragging tabs, and drawing them. (Where the tabs
    # go is worked out by TabStrip, in tab.rb.) Included into TerminalWindow.
    module TabStripView
      include Theme

      # Puts a tab in this window (new, or moved from another) and shows it.
      def add_tab(tab, index: @tabs.size, select: true)
        @tabs.insert(index.clamp(0, @tabs.size), tab)
        tab.controller.background = true # until it is the one on show
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

      def select_tab(tab)
        return if tab.nil? || tab.equal?(@tab)

        @tab&.selection = @selection
        @tab&.controller&.background = true
        @tab = tab
        @controller = tab.controller
        @controller.background = false
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
        step = text_box_key(event)
        case step
        when :escape then @tab_edit = nil
        when :enter then finish_tab_edit
        when :backspace
          edit[:all] ? edit[:text] = +"" : edit[:text].chop!
          edit[:all] = false
        when Array
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

      def step_tab(step)
        i = @tabs.index(@tab) || 0
        select_tab(@tabs[(i + step) % @tabs.size])
      end

      def next_tab = step_tab(1)
      def prev_tab = step_tab(-1)
      def tab_to_new_window(tab = @tab) = @program.tab_to_new_window(self, tab)

      # Without the custom title bar: a row across the top for the tabs.
      def draw_strip_row(w)
        @painter.fill_rect(0, 0, w, TAB_STRIP_H, TITLE_BG)
        draw_tabs(8, w - 8, 0, TAB_STRIP_H)
      end

      # The tabs between x0 and x1, then the + button. A tab being dragged
      # follows the mouse, drawn last so it's on top.
      def draw_tabs(x0, x1, top, h)
        @strip = [x0, x1, top, top + h]
        @tab_hits = HitMap.new
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
        if (tint = TAB_COLORS[tab.color])
          # The session's color. The active tab is lit up: a stronger wash, a
          # thick bar along the top and colored sides, so it stands out among
          # tabs of the same color. The others get a faint wash and a thin bar.
          if active
            pt.fill_rect(x, y, width, th, tint, 0.30)
            pt.fill_rect(x, y, width, 4, tint)
            pt.fill_rect(x, y, 2, th, tint)
            pt.fill_rect(x + width - 2, y, 2, th, tint)
          else
            pt.fill_rect(x, y, width, th, tint, 0.10)
            pt.fill_rect(x + 6, y + 2, width - 12, 2, tint, 0.55)
          end
        elsif active
          pt.fill_rect(x, y, width, 2, SELECTION) # an uncolored active tab still gets a line on top
        end
        color = { connected: ONLINE, connecting: CONNECTING }[tab.state]
        cy = y + (th / 2.0)
        color ? pt.fill_circle(x + 13, cy, 3.5, color) : pt.stroke_circle(x + 13, cy, 3.2, OFFLINE, 1.2)
        text_y = y + ((th - ui_line_h) / 2.0)
        if @tab_edit && @tab_edit[:tab].equal?(tab)
          @tab_hits.add(x, y, width, th, [:tab, index])
          return draw_tab_edit(x + 21, y + 4, [width - 21 - 6, 40].max, th - 8, text_y)
        end

        ui_text(x + 23, text_y, fit_text(tab.title, width - 23 - 26), active ? WHITE : TITLE_MUTED) if width >= 60
        if (active || hover) && width >= 60
          cx = x + width - 15
          if @tab_hover == [:tab_close, index]
            pt.fill_rect(cx - 8, cy - 8, 16, 16, TAB_HOVER, 0.14)
          end
          pt.polyline([cx - 4, cy - 4, cx + 4, cy + 4], TITLE_FG)
          pt.polyline([cx + 4, cy - 4, cx - 4, cy + 4], TITLE_FG)
          @tab_hits.add(cx - 8, cy - 8, 16, 16, [:tab_close, index])
        end
        @tab_hits.add(x, y, width, th, [:tab, index])
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
        @tab_hits.add(cx - 12, cy - 12, 24, 24, [:new_tab])
      end

      def tab_hit(event) = @tab_hits.at(event)

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
        items = ["New Tab", ["Duplicate Tab", !tab.controller.last_target.nil?], "Rename Tab", "Tab Color...",
                 ["Move Tab to New Window", many], nil, "Close Tab", ["Close Other Tabs", many]]
        case Win32.choose(@area.control, items)
        when 0 then new_tab
        when 1 then duplicate_tab(tab)
        when 2 then rename_tab(tab)
        when 3 then choose_tab_color(tab)
        when 4 then tab_to_new_window(tab)
        when 6 then close_tab(tab)
        when 7 then (@tabs - [tab]).each { |t| close_tab(t) }
        end
      end

      # Session > Tab Color (or right-click a tab): a list of colors to pick
      # from. A saved session keeps the color (every tab on it, from now on);
      # a session that isn't saved has it for this tab only.
      def choose_tab_color(tab = @tab)
        return unless tab

        names = [nil, *TAB_COLORS.keys]
        items = names.map { |n| "#{n ? n.capitalize : 'No Color'}#{'   (now)' if n == tab.color}" }
        choice = Win32.choose(@area.control, items)
        set_tab_color(tab, names[choice]) if choice
      end

      def set_tab_color(tab, name)
        if (conn = tab.saved_connection)
          conn["color"] = name.to_s
          @config.save
        else
          tab.color = name
        end
        @program.for_all(:redraw) # other tabs on the session, in any window
      end
    end
  end
end
