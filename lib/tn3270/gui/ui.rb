# frozen_string_literal: true

require "libui"

module Tn3270
  module Gui
    UI = ::LibUI

    # A thin layer over the raw libui gem (no Glimmer, so far fewer files to
    # load). It builds widgets, keeps Ruby callbacks alive while C holds on
    # to them, and turns libui's event structs into plain hashes.
    #
    # The libui gem keeps a block passed to a widget's on_* function alive by
    # storing it on that widget's pointer object; Ui.keep holds on to those
    # objects (and to the handler structs below) so nothing C calls is freed.
    module Ui
      module_function

      # Widgets and handlers that C calls back into. A callback freed by Ruby
      # while its widget still exists would crash the app, so everything with a
      # callback is kept for the life of the process (a few hundred bytes each).
      KEEP = [] # rubocop:disable Style/MutableConstant

      def keep(obj)
        KEEP << obj
        obj
      end

      # ---- text ------------------------------------------------------------------

      # A string returned by libui that the caller must free.
      def take_text(ptr)
        return "" if ptr.nil? || ptr.null?

        text = ptr.to_s.force_encoding("UTF-8")
        UI.free_text(ptr)
        text
      end

      def entry_text(entry) = take_text(UI.entry_text(entry))
      def flag(value) = value ? 1 : 0

      # ---- widgets ---------------------------------------------------------------

      def vbox(padded: true) = UI.new_vertical_box.tap { |b| UI.box_set_padded(b, flag(padded)) }
      def hbox(padded: true) = UI.new_horizontal_box.tap { |b| UI.box_set_padded(b, flag(padded)) }

      def add(box, child, stretchy: false)
        UI.box_append(box, child, flag(stretchy))
        child
      end

      def label(text) = UI.new_label(text.to_s)

      def button(text, &block)
        b = UI.new_button(text)
        UI.button_on_clicked(b) { block.call; nil }
        keep(b)
      end

      def entry(text = "")
        e = UI.new_entry
        UI.entry_set_text(e, text.to_s)
        e
      end

      def checkbox(text, checked: false, &on_toggle)
        c = UI.new_checkbox(text)
        UI.checkbox_set_checked(c, flag(checked))
        UI.checkbox_on_toggled(c) { on_toggle.call; nil } if on_toggle
        keep(c)
      end

      def checked?(checkbox) = UI.checkbox_checked(checkbox) == 1

      def spinbox(min, max, value, &on_change)
        s = UI.new_spinbox(min, max)
        UI.spinbox_set_value(s, value)
        UI.spinbox_on_changed(s) { on_change.call(UI.spinbox_value(s)); nil } if on_change
        on_change ? keep(s) : s
      end

      def combobox(items, selected: 0, &on_select)
        c = UI.new_combobox
        items.each { |i| UI.combobox_append(c, i) }
        UI.combobox_set_selected(c, selected)
        UI.combobox_on_selected(c) { on_select.call(UI.combobox_selected(c)); nil } if on_select
        keep(c)
      end

      def set_items(combo, items, selected)
        UI.combobox_clear(combo)
        items.each { |i| UI.combobox_append(combo, i) }
        UI.combobox_set_selected(combo, selected)
      end

      def form(padded: true) = UI.new_form.tap { |f| UI.form_set_padded(f, flag(padded)) }

      def grid(padded: true) = UI.new_grid.tap { |g| UI.grid_set_padded(g, flag(padded)) }

      # Puts a control in a grid cell, stretched to fill it.
      def grid_add(grid, control, col, row, xspan: 1)
        UI.grid_append(grid, control, col, row, xspan, 1, 1, UI::AlignFill, 0, UI::AlignFill)
        control
      end

      def form_row(form, label, control, stretchy: false)
        UI.form_append(form, label, control, flag(stretchy))
        control
      end

      def group(title, child, margined: true)
        g = UI.new_group(title)
        UI.group_set_margined(g, flag(margined))
        UI.group_set_child(g, child)
        g
      end

      def window(title, width, height, menubar: false, margined: true)
        w = UI.new_window(title, width, height, flag(menubar))
        UI.window_set_margined(w, flag(margined))
        keep(w)
      end

      def show(control) = UI.control_show(control)
      def hide(control) = UI.control_hide(control)
      def visible?(control) = UI.control_visible(control) == 1
      def enable(control, on) = on ? UI.control_enable(control) : UI.control_disable(control)

      # The file the user picked, or nil.
      def open_file(window)
        path = take_text(UI.open_file(window))
        path.empty? ? nil : path
      end

      # ---- the drawing area ----------------------------------------------------------

      EXT_KEYS = [nil, :escape, :insert, :delete, :home, :end, :page_up, :page_down, :up, :down, :left, :right,
                  *(1..12).map { |n| :"f#{n}" }, *(0..9).map { |n| :"n#{n}" },
                  :n_dot, :n_enter, :n_add, :n_subtract, :n_multiply, :n_divide].freeze
      MODIFIERS = { 1 => :control, 2 => :alt, 4 => :shift, 8 => :command }.freeze

      def modifiers(bits) = MODIFIERS.filter_map { |bit, name| name if bits.anybits?(bit) }

      # A drawing area. Handlers get plain hashes:
      #   draw:  { context:, area_width:, area_height: }
      #   mouse: { x:, y:, area_width:, area_height:, down:, up:, count:, modifiers:, held: }
      #   key:   { key:, key_value:, ext_key:, modifier:, modifiers:, up: }  -> true if used
      #   crossed: called with true when the mouse leaves
      class Area
        V = Fiddle::TYPE_VOID
        P = Fiddle::TYPE_VOIDP
        I = Fiddle::TYPE_INT

        attr_reader :control

        def initialize(draw:, mouse: nil, key: nil, crossed: nil)
          @handler = UI::FFI::AreaHandler.malloc
          @closures = [
            Fiddle::Closure::BlockCaller.new(V, [P, P, P]) do |_, _, params|
              p = UI::FFI::AreaDrawParams.new(params)
              guard { draw.call(context: p.Context, area_width: p.AreaWidth, area_height: p.AreaHeight) }
            end,
            Fiddle::Closure::BlockCaller.new(V, [P, P, P]) do |_, _, ev|
              next unless mouse

              e = UI::FFI::AreaMouseEvent.new(ev)
              guard do
                mouse.call(x: e.X, y: e.Y, area_width: e.AreaWidth, area_height: e.AreaHeight, down: e.Down, up: e.Up,
                           count: e.Count, modifiers: Ui.modifiers(e.Modifiers), held: e.Held1To64)
              end
            end,
            Fiddle::Closure::BlockCaller.new(V, [P, P, I]) { |_, _, left| crossed && guard { crossed.call(left == 1) } },
            Fiddle::Closure::BlockCaller.new(V, [P, P]) { |_, _| nil },
            Fiddle::Closure::BlockCaller.new(I, [P, P, P]) do |_, _, ev|
              next 0 unless key

              e = UI::FFI::AreaKeyEvent.new(ev)
              code = e.Key & 0xFF
              event = { key: code.zero? ? "" : code.chr, key_value: code, ext_key: EXT_KEYS[e.ExtKey],
                        modifier: MODIFIERS[e.Modifier], modifiers: Ui.modifiers(e.Modifiers), up: e.Up == 1 }
              guard { key.call(event) } ? 1 : 0
            end
          ]
          @handler.Draw, @handler.MouseEvent, @handler.MouseCrossed, @handler.DragBroken, @handler.KeyEvent = @closures
          @control = UI.new_area(@handler)
          Ui.keep(self)
        end

        def redraw = UI.area_queue_redraw_all(@control)

        private

        # An exception must not escape into C; report it and carry on.
        def guard
          yield
        rescue StandardError => e
          warn "#{e.class}: #{e.message}\n  #{e.backtrace.first(5).join("\n  ")}"
          nil
        end
      end

      # A read-only table of text. rows is an array of arrays of strings.
      class Table
        V = Fiddle::TYPE_VOID
        P = Fiddle::TYPE_VOIDP
        I = Fiddle::TYPE_INT

        attr_reader :control

        def initialize(columns, rows = [], &on_double_click)
          @columns = columns
          @rows = rows
          @handler = UI::FFI::TableModelHandler.malloc
          @closures = [
            Fiddle::Closure::BlockCaller.new(I, [P, P]) { |_, _| @columns.size },
            Fiddle::Closure::BlockCaller.new(I, [P, P, I]) { |_, _, _| 0 }, # every column is text
            Fiddle::Closure::BlockCaller.new(I, [P, P]) { |_, _| @rows.size },
            Fiddle::Closure::BlockCaller.new(P, [P, P, I, I]) do |_, _, row, col|
              UI.new_table_value_string(@rows.dig(row, col).to_s)
            end,
            Fiddle::Closure::BlockCaller.new(V, [P, P, I, I, P]) { |*| nil }
          ]
          @handler.NumColumns, @handler.ColumnType, @handler.NumRows, @handler.CellValue, @handler.SetCellValue = @closures
          @model = UI.new_table_model(@handler)
          @params = UI::FFI::TableParams.malloc
          @params.Model = @model
          @params.RowBackgroundColorModelColumn = -1
          @control = UI.new_table(@params)
          columns.each_with_index { |name, i| UI.table_append_text_column(@control, name, i, -1, nil) }
          Ui.keep(self)
          return unless on_double_click

          UI.table_on_row_double_clicked(@control) { |_, row, _| on_double_click.call(row); nil }
        end

        # Replaces the rows, telling the table which ones changed.
        def rows=(rows)
          old = @rows.size
          @rows = rows
          [old, rows.size].min.times { |i| UI.table_model_row_changed(@model, i) }
          (old...rows.size).each { |i| UI.table_model_row_inserted(@model, i) }
          (rows.size...old).reverse_each { |i| UI.table_model_row_deleted(@model, i) }
        end

        def set_row(index, row)
          @rows[index] = row
          UI.table_model_row_changed(@model, index)
        end

        def column_width(index, width) = UI.table_column_set_width(@control, index, width)

        # The selected row, or nil.
        def selected
          sel = UI.table_get_selection(@control)
          return nil if sel.null?

          s = UI::FFI::TableSelection.new(sel)
          row = s.NumRows.positive? ? s.Rows[0, 4].unpack1("l") : nil
          UI.free_table_selection(sel)
          row
        end
      end
    end
  end
end
