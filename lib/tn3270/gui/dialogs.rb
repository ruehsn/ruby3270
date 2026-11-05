# frozen_string_literal: true

require "glimmer-dsl-libui"
require_relative "config"
require_relative "keymap"
require_relative "shortcut"
require_relative "win32"

module Tn3270
  module Gui
    # Small helper shared by the dialogs. Glimmer's window#show starts a new
    # event loop the first time it is called, which is right for the main
    # window but not for a dialog opened from a menu.
    module DialogSupport
      def show_window(win)
        Win32.set_icon(win)
        ::LibUI.control_show(win.libui)
        win
      end
    end

    # Session > Connections...: saved connections (host, port, TLS, LU,
    # screen size) plus the path to the s3270 engine.
    class ConnectionsDialog
      include Glimmer
      include DialogSupport

      SIZE_LABELS = Config::SIZES.map(&:first) + ["Custom"]
      MAX_CELLS = 16_383 # 3270 buffer addresses are 14 bits

      def initialize(config, on_connect:, on_save: nil)
        @config = config
        @on_connect = on_connect
        @on_save = on_save
        @list = config.connections.map(&:dup)
        @list = [Config::DEFAULT_CONNECTION.dup] if @list.empty?
        @index = 0
      end

      def show
        d = self
        @win = window("Connections", 520, 460, false) {
          margined true
          vertical_box {
            padded true
            horizontal_box {
              stretchy false
              @combo = combobox {
                items d.send(:names)
                selected 0
                on_selected { |c| d.send(:pick, c.selected) }
              }
              button("New") {
                stretchy false
                on_clicked { d.send(:add) }
              }
              button("Delete") {
                stretchy false
                on_clicked { d.send(:delete) }
              }
            }
            group("Connection") {
              stretchy false
              form {
                padded true
                @name = entry { label "Name" }
                @host = entry { label "Host" }
                @port = spinbox(1, 65_535) { label "Port" }
                @tls = checkbox("Use TLS") { label "Security" }
                @lu = entry { label "LU name (optional)" }
                @size = combobox {
                  label "Screen size"
                  items SIZE_LABELS
                  on_selected { |c| d.send(:size_picked, c.selected) }
                }
                @rows = spinbox(24, 255) { label "Rows" }
                @cols = spinbox(80, 255) { label "Columns" }
              }
            }
            group("Emulator engine") {
              stretchy false
              vertical_box {
                label("Path to ws3270.exe / s3270. Leave blank to use TN3270_ENGINE or PATH.\n" \
                      "Takes effect after restarting the emulator.") { stretchy false }
                horizontal_box {
                  stretchy false
                  @engine = entry { text d.send(:config)["engine"].to_s }
                  button("Browse...") {
                    stretchy false
                    on_clicked do
                      path = open_file
                      d.send(:engine_entry).text = path.to_s unless path.to_s.empty?
                    end
                  }
                }
              }
            }
            @error = label("") { stretchy false }
            horizontal_box {
              stretchy false
              label("")
              button("Save") {
                stretchy false
                on_clicked { d.send(:save) }
              }
              button("Connect") {
                stretchy false
                on_clicked { d.send(:connect) }
              }
              button("Close") {
                stretchy false
                on_clicked { d.send(:close) }
              }
            }
          }
        }
        load_form
        show_window(@win)
      end

      private

      attr_reader :config

      def engine_entry = @engine
      def names = @list.map { |c| c["name"].to_s.empty? ? Config.connect_string(c) : c["name"] }

      def pick(index)
        return if index.negative? || index == @index

        read_form
        @index = index
        load_form
      end

      def add
        read_form
        @list << Config::DEFAULT_CONNECTION.merge("name" => "New connection", "host" => "")
        @index = @list.size - 1
        refresh_combo
        load_form
      end

      def delete
        @list.delete_at(@index)
        @list << Config::DEFAULT_CONNECTION.dup if @list.empty?
        @index = [@index, @list.size - 1].min
        refresh_combo
        load_form
        persist
      end

      def refresh_combo
        @combo.items = names
        @combo.selected = @index
      end

      def load_form
        c = @list[@index]
        @name.text = c["name"].to_s
        @host.text = c["host"].to_s
        @port.value = c["port"].to_i
        @tls.checked = !!c["tls"]
        @lu.text = c["lu"].to_s
        rows = c["rows"].to_i
        cols = c["cols"].to_i
        @rows.value = rows
        @cols.value = cols
        idx = Config::SIZES.index { |_, r, k| r == rows && k == cols } || SIZE_LABELS.size - 1
        @size.selected = idx
        size_picked(idx)
        @error.text = ""
      end

      def size_picked(index)
        custom = index == SIZE_LABELS.size - 1
        @rows.enabled = custom
        @cols.enabled = custom
        return if custom || index.negative?

        _, rows, cols = Config::SIZES[index]
        @rows.value = rows
        @cols.value = cols
      end

      def read_form
        @list[@index] = {
          "name" => @name.text.to_s.strip, "host" => @host.text.to_s.strip, "port" => @port.value.to_i,
          "tls" => @tls.checked, "lu" => @lu.text.to_s.strip,
          "rows" => @rows.value.to_i, "cols" => @cols.value.to_i
        }
      end

      # Returns an error message or nil.
      def problem
        c = @list[@index]
        return "Enter a host name or address." if c["host"].empty?
        return "Host should not include a port; use the Port box." if c["host"].include?(":")
        return "Screen too large: rows x columns must be at most #{MAX_CELLS}." if c["rows"] * c["cols"] > MAX_CELLS

        nil
      end

      # Saves the list. With shortcut: also writes that connection's desktop
      # shortcut; returns its path (or nil).
      def persist(shortcut: nil)
        before = config.connections
        config["connections"] = @list
        engine = @engine.text.to_s.strip
        config["engine"] = engine.empty? ? nil : engine
        config.save
        @on_save&.call
        update_shortcuts(before, shortcut)
      end

      # Removes shortcuts of renamed or deleted connections, then makes this one's.
      def update_shortcuts(before, conn)
        return nil unless config["desktop_shortcuts"]

        kept = @list.map { |c| Shortcut.path_for(c) }
        before.each { |c| Shortcut.remove(c) unless kept.include?(Shortcut.path_for(c)) }
        conn && Shortcut.create(conn)
      end

      def save
        read_form
        if (msg = problem)
          @error.text = msg
          return false
        end
        refresh_combo
        link = persist(shortcut: @list[@index])
        @error.text = link ? "Saved. Desktop shortcut: #{File.basename(link)}" : "Saved."
        true
      end

      def connect
        return unless save

        @on_connect.call(@list[@index])
        close
      end

      def close = @win.destroy
    end

    # Keys > Keyboard Mapping...: bind any key combination to any action.
    class KeysDialog
      include Glimmer
      include DialogSupport

      def initialize(config, on_change:)
        @config = config
        @on_change = on_change
        # Editing and other keys first; PA and PF keys at the bottom.
        aid, other = Keymap::ACTIONS.to_a.partition { |action, _| action.match?(/\Ap[af]\d+\z/) }
        @actions = other + aid.sort_by { |action, _| [action.start_with?("pf") ? 1 : 0, action[2..].to_i] }
      end

      def show
        d = self
        @rows = @actions.map { |action, label| [label, keys_text(action)] }
        @win = window("Keyboard Mapping", 560, 600, false) {
          margined true
          vertical_box {
            label("Double-click an action to change its keys.") { stretchy false }
            @table = table {
              text_column("Action")
              text_column("Keys")
              cell_rows d.send(:table_rows)
              on_row_double_clicked { |_table, row| d.send(:edit, row) }
            }
            @status = label("") { stretchy false }
            horizontal_box {
              stretchy false
              button("Edit...") { on_clicked { d.send(:edit, d.send(:selected_index)) } }
              button("Remove Keys") { on_clicked { d.send(:remove) } }
              button("Reset All") { on_clicked { d.send(:reset_all) } }
              button("Close") { on_clicked { d.send(:close) } }
            }
          }
        }
        show_window(@win)
        Win32.set_column_widths(@table, [240, -2])
      end

      private

      def table_rows = @rows
      def overrides = (@config["keys"] || {}).dup
      def bindings = Keymap.bindings(@config["keys"])
      def keys_text(action) = Keymap.keys_for(bindings, action).join(", ")

      def selected_index
        i = @table.selection
        i.is_a?(Integer) && i >= 0 ? i : nil
      end

      def selected_action = (i = selected_index) && @actions[i][0]

      # A small window for one action: shows its keys and waits for a new one.
      def edit(index)
        return @status.text = "Select an action first." unless index && @actions[index]

        @editor&.destroy
        d = self
        action, label_text = @actions[index]
        tap = Keymap::ModifierTap.new { |mod| Win32.modifier_side(mod) }
        current = nil
        replace = nil
        catcher = nil
        @editor = window("Edit Key - #{label_text}", 440, 250, false) {
          margined true
          vertical_box {
            label("#{label_text}") { stretchy false }
            current = label("Current keys: #{d.send(:keys_text, action).then { |t| t.empty? ? '(none)' : t }}") { stretchy false }
            replace = checkbox("Replace the current keys (otherwise add another)") {
              stretchy false
              checked true
            }
            catcher = area {
              on_draw do |params|
                w = params[:area_width]
                h = params[:area_height]
                pen = { r: 0x4C, g: 0x8D, b: 0xFF, a: 0.9, thickness: 1.5, dashes: [5, 4] }
                rectangle(1, 1, w - 2, h - 2) { fill r: 0xF4, g: 0xF7, b: 0xFC; stroke pen }
                text(0, (h / 2.0) - 18, w) {
                  align :center
                  default_font family: "Segoe UI", size: 10.5
                  string("Press a key or key combination now\n(Right Ctrl and other modifiers on their own work too)") { color r: 0x33, g: 0x3D, b: 0x4D }
                }
              end
              on_mouse_up { |_| Win32.focus_control(catcher) }
              on_key_event do |event|
                chord = tap.feed(event)
                chord ||= Keymap.chord(event) unless event[:up]
                d.send(:bind, chord, action, replace: replace.checked) if chord
                true
              end
            }
            horizontal_box {
              stretchy false
              button("Clear Keys") {
                on_clicked do
                  d.send(:remove_action, action)
                  current.text = "Current keys: (none)"
                end
              }
              button("Close") { on_clicked { d.send(:close_editor) } }
            }
          }
        }
        show_window(@editor)
        Win32.focus_control(catcher)
      end

      def close_editor
        @editor&.destroy
        @editor = nil
      end

      def bind(chord, action, replace: false)
        o = overrides
        previous = bindings[chord]
        Keymap.keys_for(bindings, action).each { |c| o[c] = "" } if replace
        o[chord] = action
        save(o)
        note = previous && previous != action ? " (was #{Keymap::ACTIONS[previous]})" : ""
        @status.text = "#{chord} -> #{Keymap::ACTIONS[action]}#{note}"
        # Close after this key event has finished being handled.
        Glimmer::LibUI.queue_main { close_editor }
      end

      def remove_action(action)
        o = overrides
        Keymap.keys_for(bindings, action).each { |chord| o[chord] = "" }
        save(o)
      end

      def remove
        action = selected_action
        return @status.text = "Select an action first." unless action

        remove_action(action)
        @status.text = "Removed keys for #{Keymap::ACTIONS[action]}."
      end

      def reset_all
        save({})
        @status.text = "All keys reset to defaults."
      end

      def save(overrides)
        # Drop overrides that match the default.
        @config["keys"] = overrides.reject { |chord, action| Keymap::DEFAULTS[chord] == action || (action == "" && !Keymap::DEFAULTS.key?(chord)) }
        @config.save
        @actions.each_with_index { |(action, label), i| @rows[i] = [label, keys_text(action)] }
        @on_change.call
      end

      def close
        close_editor
        @win.destroy
      end
    end

    # View > Font...: pick the screen font. Size always follows the window.
    class FontDialog
      include Glimmer
      include DialogSupport

      def initialize(config, on_change:)
        @config = config
        @on_change = on_change
      end

      def show
        d = self
        @win = window("Display Font", 380, 150, false) {
          margined true
          vertical_box {
            label("Current font: #{@config['font']}\nPick a monospaced font; the size follows the window.") { stretchy false }
            @button = font_button { stretchy false }
            horizontal_box {
              stretchy false
              label("")
              button("Apply") {
                stretchy false
                on_clicked { d.send(:apply) }
              }
              button("Close") {
                stretchy false
                on_clicked { d.send(:close) }
              }
            }
          }
        }
        show_window(@win)
      end

      private

      def apply
        family = @button.family.to_s
        return if family.empty?

        @config["font"] = family
        @config.save
        @on_change.call
        close
      end

      def close = @win.destroy
    end
  end
end
