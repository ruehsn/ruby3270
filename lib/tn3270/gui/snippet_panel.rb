# frozen_string_literal: true

require_relative "snippet_library"
require_relative "snippet_dialogs"
require_relative "../snippet"

module Tn3270
  module Gui
    # The snippets sidebar and the Ctrl+Space quick picker. Both are drawn in
    # the main window's drawing area (under the title bar, above the status
    # bar), so they look like the rest of the window. Included into App.
    #
    # Sidebar: click the search box to type a filter; Up / Down choose, Enter
    # (or a double-click) types the snippet, Escape gives the keyboard back to
    # the screen. Rest the pointer on a snippet to see its text.
    # Picker: type to filter, Up / Down, Enter types it, Escape closes.
    module SnippetPanel
      PANEL_W = 290
      ROW_H = 40
      PICKER_W = 520
      PICKER_ROWS = 10
      PANEL_BG = [0x12, 0x17, 0x1F].freeze
      FIELD_BG = [0x0B, 0x0E, 0x12].freeze
      ROW_SEL = [0x23, 0x3A, 0x5E].freeze
      RED = [0xFF, 0x6B, 0x6B].freeze
      PANEL_BUTTONS = [["Run", :run], ["New", :new], ["Edit", :edit], ["Delete", :delete], ["Files", :files]].freeze

      def library
        @library ||= SnippetLibrary.new(@config).tap(&:reload_if_changed)
      end

      def snippet_bar_shown? = @config["snippet_bar"] ? true : false

      # Width the sidebar takes from the drawing area (drawing units).
      def panel_w = snippet_bar_shown? ? PANEL_W : 0

      # ---- opening and closing -----------------------------------------------------

      def toggle_snippet_bar(on)
        set_option("snippet_bar", on)
        UI.menu_item_set_checked(@snippet_item, Ui.flag(on)) if @snippet_item
        @snip_focus = false
        library.reload_if_changed if on
        @reshape = true
        redraw
      end

      def open_picker
        hide_tooltip
        library.reload_if_changed
        @picker = { query: +"", sel: 0 }
        redraw
      end

      def close_picker
        @picker = nil
        redraw
      end

      # ---- running -----------------------------------------------------------------

      def panel_items = library.search(@snip_query.to_s)
      def picker_items = library.search(@picker[:query]).first(PICKER_ROWS)

      # Types a snippet: asks for its {ask:...} values first, if it has any.
      def run_snippet_item(item)
        return unless item

        @snip_focus = false
        vars = {}
        vars[:clipboard] = Clipboard.paste if item.text.match?(/\{clipboard\}/i)
        go = ->(answers) { @controller.run_snippet(item.text, answers: answers, vars: vars, name: item.name) }
        prompts = Snippet.prompts(item.text)
        if prompts.empty?
          go.call({})
        else
          @snippet_ask = AskDialog.new(item.name, prompts, on_run: go)
          @snippet_ask.show
        end
        redraw
      end

      # Ctrl+1 ... Ctrl+9: the snippets in list order (unfiltered).
      def run_snippet_number(n)
        library.reload_if_changed
        run_snippet_item(library.items[n - 1])
      end

      def edit_snippet(item, text: nil, name: nil)
        @snippet_editor = SnippetEditor.new(library, item, text: text, name: name, on_saved: -> { snippets_changed })
        @snippet_editor.show
      end

      # From the picker: a new snippet named after what was typed, or the
      # chosen one to edit.
      def picker_new
        name = @picker[:query].strip
        close_picker
        edit_snippet(nil, name: name.empty? ? nil : name)
      end

      def picker_edit
        item = picker_items[@picker[:sel]]
        return unless item

        close_picker
        edit_snippet(item)
      end

      # Edit > New Snippet from Selection: the selected block becomes a snippet.
      def snippet_from_selection
        scr = @controller.snapshot
        text = scr && @selection ? scr.region_text(*@selection).lines.map(&:rstrip).join("\n") : ""
        edit_snippet(nil, text: text)
      end

      def delete_snippet(item)
        return unless item
        return msg_box("Snippets", "\"#{item.name}\" is in a file you can't change:\n#{item.file}") unless library.writable?(item.file)

        library.delete(item)
        snippets_changed
      end

      def snippet_files_dialog
        @snippet_files = SnippetFilesDialog.new(library, on_change: lambda {
          @config.save
          snippets_changed
        })
        @snippet_files.show
      end

      def snippets_changed
        library.reload_if_changed
        @snip_sel = @snip_sel.to_i.clamp(0, [panel_items.size - 1, 0].max)
        redraw
      end

      # ---- keyboard ----------------------------------------------------------------

      # Turns a key event into a step for a text box: [:type, ch], :backspace,
      # :enter, :escape, :up, :down, or nil.
      def text_box_key(event)
        return nil if event[:up]
        return :escape if event[:ext_key] == :escape || event[:key_value] == 27
        return :up if event[:ext_key] == :up
        return :down if event[:ext_key] == :down
        return :enter if [10, 13].include?(event[:key_value]) || event[:ext_key] == :n_enter
        return :backspace if event[:key_value] == 8

        action = Keymap.translate(event, {})
        action && action[0] == :type ? action : nil
      end

      # Keys while the picker is open. Always handled (the screen doesn't get them).
      def picker_key(event)
        if !event[:up] && event[:modifiers].include?(:control) && !event[:modifiers].include?(:alt)
          case event[:key].to_s.downcase
          when "n" then return picker_new || true
          when "e" then return picker_edit || true
          end
        end
        step = text_box_key(event)
        items = picker_items
        case step
        when :escape then close_picker
        when :enter
          item = items[@picker[:sel]]
          close_picker
          run_snippet_item(item)
        when :up then @picker[:sel] = (@picker[:sel] - 1).clamp(0, [items.size - 1, 0].max)
        when :down then @picker[:sel] = (@picker[:sel] + 1).clamp(0, [items.size - 1, 0].max)
        when :backspace then @picker[:query].chop! && @picker[:sel] = 0
        when Array then (@picker[:query] << step[1]) && @picker[:sel] = 0
        end
        redraw
        true
      end

      # Keys while the sidebar's search box has the keyboard.
      def panel_key(event)
        step = text_box_key(event)
        items = panel_items
        @snip_query ||= +""
        case step
        when :escape then @snip_focus = false
        when :enter then run_snippet_item(items[@snip_sel.to_i])
        when :up then @snip_sel = (@snip_sel.to_i - 1).clamp(0, [items.size - 1, 0].max)
        when :down then @snip_sel = (@snip_sel.to_i + 1).clamp(0, [items.size - 1, 0].max)
        when :backspace then @snip_query.chop! && @snip_sel = 0
        when Array then (@snip_query << step[1]) && @snip_sel = 0
        else return false unless event[:up] # other keys (F-keys...) still reach the screen
        end
        redraw
        true
      end

      # ---- mouse ---------------------------------------------------------------------

      # A press inside the sidebar or the picker. Returns true when it was there.
      def snippet_mouse_down(event)
        if @picker
          hit = hit_at(@picker_hits, event)
          case hit && hit[0]
          when :new then picker_new
          when :edit then picker_edit
          when :run
            close_picker
            run_snippet_item(hit[1])
          else close_picker # a click outside the picker
          end
          return true
        end
        return false unless snippet_bar_shown? && event[:x] >= event[:area_width] - PANEL_W

        hit = hit_at(@snip_hits, event)
        if hit.nil? then nil
        elsif hit[0] == :search then @snip_focus = true
        elsif hit[0] == :row
          @snip_sel = hit[1]
          run_snippet_item(panel_items[hit[1]]) if event[:count].to_i >= 2
        elsif hit[0] == :button
          panel_button(hit[1])
        end
        redraw
        true
      end

      def panel_button(action)
        item = panel_items[@snip_sel.to_i]
        case action
        when :run then run_snippet_item(item)
        when :new then edit_snippet(nil)
        when :edit then item && edit_snippet(item)
        when :delete then delete_snippet(item)
        when :files then snippet_files_dialog
        end
      end

      def hit_at(hits, event)
        found = (hits || []).find { |x, y, w, h, _| event[:x].between?(x, x + w) && event[:y].between?(y, y + h) }
        found && found[4]
      end

      # The snippet row under the pointer, for its tooltip: [:snip, index] or nil.
      def snippet_hover(event)
        hit = hit_at(@snip_hits, event)
        hit && hit[0] == :row ? [:snip, hit[1]] : nil
      end

      # ---- drawing -------------------------------------------------------------------

      def ui_line_h(size = App::UI_SIZE) = FontMetrics.for(App::UI_FONT)[:line] * size

      # Cuts text to roughly fit a width (UI font), ending in "...".
      def fit_text(text, width, size = App::UI_SIZE)
        text = text.to_s.tr("\n", " ")
        max = (width / (size * 0.62)).floor
        text.size > max ? "#{text[0, [max - 1, 1].max]}…" : text
      end

      def draw_snippet_panel(w, h)
        pt = @painter
        x0 = w - PANEL_W
        top = title_h
        bottom = h - App::STATUS_H
        @snip_hits = []
        pt.fill_rect(x0, top, PANEL_W, bottom - top, PANEL_BG)
        pt.fill_rect(x0, top, 1, bottom - top, [0x2A, 0x33, 0x40])
        x = x0 + 12
        inner = PANEL_W - 24
        y = top + 10
        ui_text(x, y, "Snippets", App::WHITE)
        hint = "#{keys_label('snippet_picker')}: quick pick"
        ui_text(x0 + PANEL_W - 12 - FontMetrics.text_width(App::UI_FONT, App::UI_SIZE, hint), y, hint, App::TITLE_MUTED)
        y += 24

        # Search box
        pt.fill_rect(x, y, inner, 26, FIELD_BG)
        pt.stroke_rect(x + 0.5, y + 0.5, inner - 1, 25, @snip_focus ? App::SELECTION : [0x2A, 0x33, 0x40], 1)
        query = @snip_query.to_s
        if query.empty? && !@snip_focus
          ui_text(x + 8, y + 5, "Search snippets", App::TITLE_MUTED)
        else
          shown = fit_text(query, inner - 20)
          ui_text(x + 8, y + 5, shown, App::TITLE_FG)
          if @snip_focus
            cx = x + 9 + FontMetrics.text_width(App::UI_FONT, App::UI_SIZE, shown)
            pt.fill_rect(cx, y + 6, 1, 15, App::TITLE_FG)
          end
        end
        @snip_hits << [x, y, inner, 26, [:search]]
        y += 34

        items = panel_items
        list_bottom = bottom - 44 - (library.errors.any? ? 20 : 0)
        visible = [((list_bottom - y) / ROW_H).floor, 1].max
        @snip_sel = @snip_sel.to_i.clamp(0, [items.size - 1, 0].max)
        @snip_scroll = @snip_scroll.to_i.clamp([@snip_sel - visible + 1, 0].max, @snip_sel)
        if items.empty?
          message = library.items.empty? ? "No snippets yet.\nClick New, or select text on the\nscreen and use Edit > New Snippet\nfrom Selection." : "No matches."
          message.lines.each_with_index { |l, i| ui_text(x, y + 4 + (i * ui_line_h), l.chomp, App::TITLE_MUTED) }
        end
        items[@snip_scroll, visible].to_a.each_with_index do |item, i|
          index = @snip_scroll + i
          ry = y + (i * ROW_H)
          pt.fill_rect(x0 + 1, ry, PANEL_W - 1, ROW_H - 2, ROW_SEL) if index == @snip_sel
          number = library.items.index(item)
          key = number && number < 9 ? Keymap.keys_for(@bindings, "snippet#{number + 1}").first : nil
          name_w = inner - (key ? FontMetrics.text_width(App::UI_FONT, App::UI_SIZE, key) + 10 : 0)
          ui_text(x, ry + 3, fit_text(item.name, name_w), App::WHITE)
          ui_text(x0 + PANEL_W - 12 - FontMetrics.text_width(App::UI_FONT, App::UI_SIZE, key), ry + 3, key, App::TITLE_MUTED) if key
          ui_text(x, ry + 3 + ui_line_h, fit_text(item.text, inner), App::TITLE_MUTED)
          @snip_hits << [x0, ry, PANEL_W, ROW_H - 2, [:row, index]]
        end
        ui_text(x, list_bottom + 2, fit_text(library.errors.first, inner), RED) if library.errors.any?

        # Buttons
        bw = (inner - ((PANEL_BUTTONS.size - 1) * 4)) / PANEL_BUTTONS.size.to_f
        by = bottom - 36
        PANEL_BUTTONS.each_with_index do |(label, action), i|
          bx = x + (i * (bw + 4))
          pt.fill_rect(bx, by, bw, 26, [0x1E, 0x26, 0x32])
          pt.stroke_rect(bx + 0.5, by + 0.5, bw - 1, 25, [0x3A, 0x46, 0x58], 1)
          tw = FontMetrics.text_width(App::UI_FONT, App::UI_SIZE, label)
          ui_text(bx + ((bw - tw) / 2.0), by + 5, label, App::TITLE_FG)
          @snip_hits << [bx, by, bw, 26, [:button, action]]
        end
      end

      # The quick picker: a box over the top of the screen.
      def draw_picker(w, _h)
        pt = @painter
        items = picker_items
        @picker[:sel] = @picker[:sel].clamp(0, [items.size - 1, 0].max)
        line = ui_line_h
        rows = [items.size, 1].max
        bw = [PICKER_W, w - panel_w - 40].min
        bh = 16 + 28 + 8 + (rows * (line * 2 + 8)) + 14 + line
        bx = ((w - panel_w - bw) / 2.0).clamp(10, w)
        by = title_h + 30
        @picker_hits = []
        pt.fill_rect(bx + 3, by + 4, bw, bh, [0, 0, 0], 0.35) # shadow
        pt.fill_rect(bx, by, bw, bh, PANEL_BG)
        pt.stroke_rect(bx + 0.5, by + 0.5, bw - 1, bh - 1, App::SELECTION, 1)
        x = bx + 10
        y = by + 10
        pt.fill_rect(x, y, bw - 20, 28, FIELD_BG)
        query = @picker[:query]
        ui_text(x + 8, y + 6, query.empty? ? "Type to find a snippet" : fit_text(query, bw - 40), query.empty? ? App::TITLE_MUTED : App::WHITE)
        cx = x + 9 + (query.empty? ? 0 : FontMetrics.text_width(App::UI_FONT, App::UI_SIZE, fit_text(query, bw - 40)))
        pt.fill_rect(cx, y + 6, 1, 16, App::TITLE_FG)
        y += 36
        if items.empty?
          ui_text(x + 8, y + 4, library.items.empty? ? "No snippets yet (View > Snippets Sidebar > New)." : "No matches.", App::TITLE_MUTED)
        end
        items.each_with_index do |item, i|
          rh = (line * 2) + 8
          pt.fill_rect(bx + 1, y, bw - 2, rh, ROW_SEL) if i == @picker[:sel]
          ui_text(x + 8, y + 4, fit_text(item.name, bw - 40), App::WHITE)
          ui_text(x + 8, y + 4 + line, fit_text(item.text, bw - 40), App::TITLE_MUTED)
          @picker_hits << [bx, y, bw, rh, [:run, item]]
          y += rh
        end
        # Footer: hints, and New / Edit buttons.
        fy = by + bh - line - 10
        ui_text(x, fy + 2, "Enter: type it   Up/Down: choose   Esc: close", App::TITLE_MUTED)
        right = bx + bw - 10 # buttons are laid out right to left
        [["Edit  Ctrl+E", :edit, !items.empty?], ["New  Ctrl+N", :new, true]].each do |label, action, enabled|
          btn_w = FontMetrics.text_width(App::UI_FONT, App::UI_SIZE, label) + 16
          btn_x = right - btn_w
          right = btn_x - 6
          pt.fill_rect(btn_x, fy - 3, btn_w, line + 6, [0x1E, 0x26, 0x32])
          pt.stroke_rect(btn_x + 0.5, fy - 2.5, btn_w - 1, line + 5, [0x3A, 0x46, 0x58], 1)
          ui_text(btn_x + 8, fy, label, enabled ? App::TITLE_FG : App::TITLE_MUTED)
          @picker_hits << [btn_x, fy - 3, btn_w, line + 6, [action]] if enabled
        end
      end
    end
  end
end
