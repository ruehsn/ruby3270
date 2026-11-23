# frozen_string_literal: true

require_relative "ui"
require_relative "config"
require_relative "keymap"
require_relative "screen_painter"
require_relative "shortcut"
require_relative "fonts"
require_relative "win32"

module Tn3270
  module Gui
    # Small helpers shared by the dialogs.
    module DialogSupport
      def show_window(win)
        Win32.set_icon(win)
        UI.control_show(win)
        win
      end

      # Closes a window from inside one of its own event handlers.
      def close_window(win)
        UI.queue_main { UI.control_destroy(win) }
      end
    end

    # Session > Edit Session...: saved connections (host, port, TLS and
    # certificate checking, LU, screen size, startup script, tab color).
    class ConnectionsDialog
      include DialogSupport

      SIZE_LABELS = Config::SIZES.map(&:first) + ["Custom"]
      COLORS = ["", *Theme::TAB_COLORS.keys].freeze # a connection's "color"; "" = none
      MAX_CELLS = 16_383 # 3270 buffer addresses are 14 bits

      # select: a connection to open the dialog on (Session > Edit Session);
      # one that isn't saved yet (typed as host:port) is added to the list.
      def initialize(config, on_connect:, on_save: nil, select: nil, title: "Connections")
        @config = config
        @on_connect = on_connect
        @on_save = on_save
        @title = title
        @list = config.connections.map { |c| Config::DEFAULT_CONNECTION.merge(c) }
        @list = [Config::DEFAULT_CONNECTION.dup] if @list.empty?
        @index = select ? index_for(select) : 0
        @opened = select && @index
        @renamed = {} # old name => new name, for desktop shortcuts
      end

      # The connection on show (after Save: as saved).
      def current = @list[@index]

      # The connection the dialog opened on (`select:`), as edited; nil once deleted.
      def opened = @opened && @list[@opened]

      def show
        @win = Ui.window(@title, 560, 540)
        UI.window_on_closing(@win) { 1 }
        main = Ui.vbox

        top = Ui.add(main, Ui.hbox)
        @combo = Ui.add(top, Ui.combobox(names) { |i| pick(i) }, stretchy: true)
        Ui.add(top, Ui.button("New") { add })
        Ui.add(top, Ui.button("Duplicate") { duplicate })
        Ui.add(top, Ui.button("Delete") { delete })

        form = Ui.form
        @name = Ui.form_row(form, "Name", Ui.entry)
        @host = Ui.form_row(form, "Host", Ui.entry)
        @port = Ui.form_row(form, "Port", Ui.spinbox(1, 65_535, 23))
        @tls = Ui.form_row(form, "Security", Ui.checkbox("Use TLS") { update_verify })
        @verify = Ui.form_row(form, "", Ui.checkbox("Verify the host's certificate (leave off for self-signed certificates)"))
        @lu = Ui.form_row(form, "LU name (optional)", Ui.entry)
        @color = Ui.form_row(form, "Tab color", Ui.combobox(COLORS.map { |c| c.empty? ? "None" : c.capitalize }))
        @size = Ui.form_row(form, "Screen size", Ui.combobox(SIZE_LABELS) { |i| size_picked(i) })
        @rows = Ui.form_row(form, "Rows", Ui.spinbox(24, 255, 24) { size_typed })
        @cols = Ui.form_row(form, "Columns", Ui.spinbox(80, 255, 80) { size_typed })
        script_row = Ui.hbox
        @script = Ui.add(script_row, Ui.entry, stretchy: true)
        Ui.add(script_row, Ui.button("Browse...") { browse_script })
        Ui.add(script_row, Ui.button("Clear") { UI.entry_set_text(@script, "") })
        Ui.form_row(form, "Startup script", script_row)
        Ui.form_row(form, "", Ui.label("Runs in the background each time this connection comes up, e.g. to log on.\n" \
                                       "Ruby (.rb), PowerShell, batch, Python... See examples/startup_script.rb."))
        Ui.add(main, Ui.group("Connection", form))

        @error = Ui.add(main, Ui.label(""))
        buttons = Ui.add(main, Ui.hbox)
        Ui.add(buttons, Ui.label(""), stretchy: true)
        Ui.add(buttons, Ui.button("Desktop Shortcut") { make_shortcut }) if Win32.available?
        Ui.add(buttons, Ui.button("Save") { save })
        Ui.add(buttons, Ui.button("Connect") { connect })
        Ui.add(buttons, Ui.button("Close") { close_window(@win) })
        UI.window_set_child(@win, main)
        UI.combobox_set_selected(@combo, @index)
        load_form
        show_window(@win)
      end

      private

      attr_reader :config

      def index_for(conn)
        conn = Config::DEFAULT_CONNECTION.merge(conn)
        same_host = ->(c) { c["host"] == conn["host"] && c["port"].to_i == conn["port"].to_i && c["lu"].to_s == conn["lu"].to_s }
        found = @list.index(conn) || @list.index { |c| c["name"] == conn["name"] } || @list.index(&same_host)
        return found if found

        @list << conn.merge("name" => conn["name"].to_s.empty? ? Config.display_string(conn) : conn["name"])
        @list.size - 1
      end

      def names = @list.map { |c| c["name"].to_s.empty? ? Config.display_string(c) : c["name"] }

      def update_verify = Ui.enable(@verify, Ui.checked?(@tls))

      def browse_script
        path = Ui.open_file(@win)
        UI.entry_set_text(@script, path) if path
      end

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

      # A copy of the connection on show, named "Name (2)", "Name (3)"...
      # Not saved until Save.
      def duplicate
        read_form
        copy = @list[@index].merge("name" => self.class.copy_name(@list[@index]["name"], names))
        @list << copy
        @index = @list.size - 1
        refresh_combo
        load_form
        UI.label_set_text(@error, "Copied. Change what you need, then Save.")
      end

      public

      # "Prod" -> "Prod (2)", or the next number no other connection uses.
      def self.copy_name(name, taken)
        base = name.to_s.sub(/ \(\d+\)\z/, "")
        base = "Connection" if base.strip.empty?
        n = 2
        n += 1 while taken.include?("#{base} (#{n})")
        "#{base} (#{n})"
      end

      private

      def delete
        @opened = nil if @opened == @index
        @opened -= 1 if @opened && @opened > @index
        @list.delete_at(@index)
        @list << Config::DEFAULT_CONNECTION.dup if @list.empty?
        @index = [@index, @list.size - 1].min
        refresh_combo
        load_form
        persist
      end

      def refresh_combo = Ui.set_items(@combo, names, @index)

      def load_form
        c = @list[@index]
        UI.entry_set_text(@name, c["name"].to_s)
        UI.entry_set_text(@host, c["host"].to_s)
        UI.spinbox_set_value(@port, c["port"].to_i)
        UI.checkbox_set_checked(@tls, Ui.flag(c["tls"]))
        UI.checkbox_set_checked(@verify, Ui.flag(c["verify_cert"]))
        update_verify
        UI.entry_set_text(@lu, c["lu"].to_s)
        UI.combobox_set_selected(@color, COLORS.index(c["color"].to_s) || 0)
        UI.entry_set_text(@script, c["script"].to_s)
        rows = c["rows"].to_i
        cols = c["cols"].to_i
        UI.spinbox_set_value(@rows, rows)
        UI.spinbox_set_value(@cols, cols)
        idx = Config::SIZES.index { |_, r, k| r == rows && k == cols } || SIZE_LABELS.size - 1
        UI.combobox_set_selected(@size, idx)
        size_picked(idx)
        UI.label_set_text(@error, "")
      end

      # A size from the list fills in Rows and Columns; "Custom" leaves them
      # for you to type.
      def size_picked(index)
        return if index == SIZE_LABELS.size - 1 || index.negative?

        _, rows, cols = Config::SIZES[index]
        UI.spinbox_set_value(@rows, rows)
        UI.spinbox_set_value(@cols, cols)
      end

      # Rows or Columns typed: the list shows the matching size, or Custom.
      def size_typed
        rows = UI.spinbox_value(@rows)
        cols = UI.spinbox_value(@cols)
        idx = Config::SIZES.index { |_, r, k| r == rows && k == cols } || SIZE_LABELS.size - 1
        UI.combobox_set_selected(@size, idx) unless UI.combobox_selected(@size) == idx
      end

      def read_form
        was = @list[@index]["name"].to_s
        @list[@index] = {
          "name" => Ui.entry_text(@name).strip, "host" => Ui.entry_text(@host).strip,
          "port" => UI.spinbox_value(@port), "tls" => Ui.checked?(@tls), "verify_cert" => Ui.checked?(@verify),
          "lu" => Ui.entry_text(@lu).strip, "rows" => UI.spinbox_value(@rows), "cols" => UI.spinbox_value(@cols),
          "script" => Ui.entry_text(@script).strip, "color" => COLORS[UI.combobox_selected(@color)].to_s
        }
        now = @list[@index]["name"]
        @renamed[was] = now unless was.empty? || was == now
      end

      # Returns an error message or nil.
      def problem
        c = @list[@index]
        return "Enter a host name or address." if c["host"].empty?
        return "Host should not include a port; use the Port box." if c["host"].include?(":")
        return "Screen too large: rows x columns must be at most #{MAX_CELLS}." if c["rows"] * c["cols"] > MAX_CELLS
        return "Startup script not found: #{c['script']}" unless c["script"].empty? || File.file?(c["script"])

        nil
      end

      # Saves the list. Desktop shortcuts are only made by the Desktop
      # Shortcut button, but one that exists follows its session: a deleted
      # session's goes, a renamed session's is remade under the new name.
      def persist
        before = config.connections
        config["connections"] = @list
        config.save
        @on_save&.call
        update_shortcuts(before)
      end

      def update_shortcuts(before)
        kept = @list.map { |c| Shortcut.path_for(c) }
        before.each do |c|
          next if kept.include?(Shortcut.path_for(c))
          next unless Shortcut.remove(c) # it had a shortcut (one this app made)

          (now = renamed_to(c["name"])) && Shortcut.create(now)
        end
      end

      # The connection now called what `name` was renamed to, or nil.
      def renamed_to(name)
        seen = []
        while (n = @renamed[name]) && !seen.include?(n)
          seen << n
          name = n
        end
        seen.empty? ? nil : @list.find { |c| c["name"] == name }
      end

      def save
        read_form
        if (msg = problem)
          UI.label_set_text(@error, msg)
          return false
        end
        refresh_combo
        persist
        UI.label_set_text(@error, "Saved.")
        true
      end

      # The Desktop Shortcut button: saves, then puts a shortcut to this
      # session on the desktop (double-click it to open ruby3270 on it).
      def make_shortcut
        return unless save

        link = Shortcut.create(@list[@index])
        UI.label_set_text(@error, link ? "Saved. Desktop shortcut: #{File.basename(link)}" : "Saved, but the shortcut couldn't be made.")
      end

      def connect
        return unless save

        @on_connect.call(@list[@index])
        close_window(@win)
      end
    end

    # Session > Program Settings...: options for the whole program rather
    # than one session: the engine, keyboard, spelling, snippets, window shape.
    # Check boxes act at once (through the same switches as the menus); the
    # engine path is kept by Save.
    class SettingsDialog
      include DialogSupport

      # program: the Program (its `flip` keeps the menu ticks in step);
      # window: the TerminalWindow the dialog was opened from.
      def initialize(program, window)
        @program = program
        @window = window
        @config = program.config
      end

      def show
        @win = Ui.window("Program Settings", 600, 560)
        UI.window_on_closing(@win) { 1 }
        main = Ui.vbox

        engine = Ui.vbox
        Ui.add(engine, Ui.label("Path to ws3270.exe / s3270. Leave blank to find it automatically.\n" \
                                "Takes effect after restarting the emulator."))
        row = Ui.add(engine, Ui.hbox)
        @engine = Ui.add(row, Ui.entry(@config["engine"]), stretchy: true)
        Ui.add(row, Ui.button("Browse...") { browse_engine })
        Ui.add(main, Ui.group("Emulator engine", engine))

        keys = Ui.vbox
        toggle(keys, "Type-ahead (queue keys while the host is busy)", :typeahead, "typeahead")
        toggle(keys, "Numeric fields: digits only", :numeric_lock, "numeric_lock")
        Ui.add(keys, Ui.button("Keyboard Mapping...") { @window.command(:keys_dialog) })
        Ui.add(main, Ui.group("Keyboard", keys))

        if Win32.available?
          spelling = Ui.vbox
          toggle(spelling, "Spell check (long input fields)", :spell_check, "spell_check")
          lrow = Ui.add(spelling, Ui.hbox)
          Ui.add(lrow, Ui.label("Check words at least this many letters long:"))
          Ui.add(lrow, Ui.spinbox(1, 20, @config["spell_min_word"].to_i) { |n| @program.for_all(:set_spell_min_word, n) })
          Ui.add(spelling, Ui.label("Skip patterns in your word list: AC?????? = 8 letters starting with AC (? one letter, * any)"))
          srow = Ui.add(spelling, Ui.hbox)
          Ui.add(srow, Ui.button("Language...") { @window.command(:choose_spell_language) })
          Ui.add(srow, Ui.button("Edit My Spelling Words...") { @window.command(:edit_spell_words) })
          Ui.add(main, Ui.group("Spelling", spelling))
        end

        snippets = Ui.vbox
        toggle(snippets, "Show the snippets sidebar", :snippet_bar, "snippet_bar")
        nrow = Ui.add(snippets, Ui.hbox)
        Ui.add(nrow, Ui.button("Snippet Files...") { @window.command(:snippet_files_dialog) })
        Ui.add(nrow, Ui.button("Quick Pick...") { @window.command(:open_picker) })
        Ui.add(nrow, Ui.button("Refresh Snippets") { @window.command(:refresh_snippets) })
        Ui.add(main, Ui.group("Snippets", snippets))

        if Win32.available?
          shape = Ui.vbox
          toggle(shape, "Lock the window shape to the screen", :lock_ratio, "lock_ratio")
          Ui.add(main, Ui.group("Window", shape))
        end

        @note = Ui.add(main, Ui.label(""))
        buttons = Ui.add(main, Ui.hbox)
        Ui.add(buttons, Ui.label(""), stretchy: true)
        Ui.add(buttons, Ui.button("Save") { save })
        Ui.add(buttons, Ui.button("Close") { close_window(@win) })
        UI.window_set_child(@win, main)
        show_window(@win)
      end

      private

      # A check box for the setting `key`; clicking it flips the setting like its menu item.
      def toggle(box, text, name, key)
        Ui.add(box, Ui.checkbox(text, checked: @config[key]) { @program.flip(name, @window) })
      end

      def browse_engine
        path = Ui.open_file(@win)
        UI.entry_set_text(@engine, path) if path
      end

      def save
        engine = Ui.entry_text(@engine).strip
        @config["engine"] = engine.empty? ? nil : engine
        @config.save
        UI.label_set_text(@note, "Saved.")
      end
    end

    # Keys > Keyboard Mapping...: bind any key combination to any action.
    class KeysDialog
      include DialogSupport

      PAD_BG = [0xF4, 0xF7, 0xFC].freeze
      PAD_LINE = [0x4C, 0x8D, 0xFF].freeze
      PAD_TEXT = [0x33, 0x3D, 0x4D].freeze

      def initialize(config, on_change:)
        @config = config
        @on_change = on_change
        # Editing and other keys first; PA and PF keys at the bottom.
        aid, other = Keymap::ACTIONS.to_a.partition { |action, _| action.match?(/\Ap[af]\d+\z/) }
        @actions = other + aid.sort_by { |action, _| [action.start_with?("pf") ? 1 : 0, action[2..].to_i] }
        @painter = Painter.new
      end

      def show
        @win = Ui.window("Keyboard Mapping", 560, 600)
        UI.window_on_closing(@win) do
          close_editor
          1
        end
        main = Ui.vbox
        Ui.add(main, Ui.label("Double-click an action to change its keys."))
        @table = Ui::Table.new(%w[Action Keys], table_rows) { |row| edit(row) }
        Ui.add(main, @table.control, stretchy: true)
        @status = Ui.add(main, Ui.label(""))
        buttons = Ui.add(main, Ui.hbox)
        Ui.add(buttons, Ui.button("Edit...") { edit(@table.selected) }, stretchy: true)
        Ui.add(buttons, Ui.button("Remove Keys") { remove }, stretchy: true)
        Ui.add(buttons, Ui.button("Reset All") { reset_all }, stretchy: true)
        Ui.add(buttons, Ui.button("Close") { close_editor; close_window(@win) }, stretchy: true)
        UI.window_set_child(@win, main)
        show_window(@win)
        @table.column_width(0, 240)
        Win32.set_column_widths(@table.control, [240, -2])
      end

      private

      def table_rows = @actions.map { |action, label| [label, keys_text(action)] }
      def overrides = (@config["keys"] || {}).dup
      def bindings = Keymap.bindings(@config["keys"])
      def keys_text(action) = Keymap.keys_for(bindings, action).join(", ")
      def status(text) = UI.label_set_text(@status, text)

      def selected_action = (i = @table.selected) && @actions[i][0]

      # A small window for one action: shows its keys and waits for a new one.
      def edit(index)
        return status("Select an action first.") unless index && @actions[index]

        close_editor
        action, label_text = @actions[index]
        tap = Keymap::ModifierTap.new { |mod| Win32.modifier_side(mod) }
        @editor = Ui.window("Edit Key - #{label_text}", 440, 250)
        UI.window_on_closing(@editor) do
          @editor = nil
          1
        end
        box = Ui.vbox
        Ui.add(box, Ui.label(label_text))
        current = Ui.add(box, Ui.label("Current keys: #{keys_text(action).then { |t| t.empty? ? '(none)' : t }}"))
        replace = Ui.add(box, Ui.checkbox("Replace the current keys (otherwise add another)", checked: true))
        @catcher = Ui::Area.new(
          draw: ->(p) { draw_catcher(p) },
          mouse: ->(e) { Win32.focus_control(@catcher.control) if e[:up] == 1 },
          key: lambda { |event|
            chord = tap.feed(event)
            chord ||= Keymap.chord(event) unless event[:up]
            bind(chord, action, replace: Ui.checked?(replace)) if chord
            true
          }
        )
        Ui.add(box, @catcher.control, stretchy: true)
        buttons = Ui.add(box, Ui.hbox)
        Ui.add(buttons, Ui.button("Clear Keys") {
          remove_action(action)
          UI.label_set_text(current, "Current keys: (none)")
        }, stretchy: true)
        Ui.add(buttons, Ui.button("Close") { close_editor }, stretchy: true)
        UI.window_set_child(@editor, box)
        show_window(@editor)
        Win32.focus_control(@catcher.control)
      end

      def draw_catcher(params)
        pt = @painter
        pt.context = params[:context]
        w = params[:area_width]
        h = params[:area_height]
        pt.fill_rect(1, 1, w - 2, h - 2, PAD_BG)
        pt.stroke_rect(1, 1, w - 2, h - 2, PAD_LINE, 1.5, 0.9)
        pt.text(0, (h / 2.0) - 18, w, "Press a key or key combination now\n(Right Ctrl and other modifiers on their own work too)",
                PAD_TEXT, "Segoe UI", 10.5, align: :center)
      end

      def close_editor
        return unless @editor

        editor = @editor
        @editor = nil
        UI.queue_main { UI.control_destroy(editor) }
      end

      def bind(chord, action, replace: false)
        o = overrides
        previous = bindings[chord]
        Keymap.keys_for(bindings, action).each { |c| o[c] = "" } if replace
        o[chord] = action
        save(o)
        note = previous && previous != action ? " (was #{Keymap::ACTIONS[previous]})" : ""
        status("#{chord} -> #{Keymap::ACTIONS[action]}#{note}")
        # Close after this key event has finished being handled.
        close_editor
      end

      def remove_action(action)
        o = overrides
        Keymap.keys_for(bindings, action).each { |chord| o[chord] = "" }
        save(o)
      end

      def remove
        action = selected_action
        return status("Select an action first.") unless action

        remove_action(action)
        status("Removed keys for #{Keymap::ACTIONS[action]}.")
      end

      def reset_all
        save({})
        status("All keys reset to defaults.")
      end

      def save(overrides)
        # Drop overrides that match the default.
        @config["keys"] = overrides.reject { |chord, action| Keymap::DEFAULTS[chord] == action || (action == "" && !Keymap::DEFAULTS.key?(chord)) }
        @config.save
        @table.rows = table_rows
        @on_change.call
      end
    end

    # View > Font...: pick the screen font from the installed monospaced fonts,
    # with a preview in that font. Size always follows the window.
    class FontDialog
      include DialogSupport
      include ScreenPainter

      PREVIEW_SIZE = 13
      # Sample lines for the preview: [text, colour, bright?]
      SAMPLE = [
        ["FAKEHOST                SIGN ON", :turquoise, true],
        ["USER ID  ===> USER01    PASSWORD ===>", :green, false],
        ["0123456789  ABCDEFGHIJKLM  abcdefghijklm", :neutral, false],
        ["{}[]()<>|/\  @#$%&*  -_=+  .,:;'\"", :yellow, false],
        ["PF3=End   PF7=Up   PF8=Down   ENTER=Go", :blue, false]
      ].freeze

      def initialize(config, on_change:)
        @config = config
        @on_change = on_change
        @painter = Painter.new
      end

      def show
        @fonts = Fonts.monospaced(@config["font"])
        @font = @config["font"]
        @win = Ui.window("Display Font", 520, 300)
        UI.window_on_closing(@win) { 1 }
        box = Ui.vbox
        @choice = Ui.add(box, Ui.combobox(@fonts, selected: @fonts.index(@font) || 0) { |i| pick(i) })
        @preview = Ui::Area.new(draw: ->(p) { draw_preview(p) })
        Ui.add(box, @preview.control, stretchy: true)
        row = Ui.add(box, Ui.hbox)
        Ui.add(row, Ui.label("The size follows the window."), stretchy: true)
        Ui.add(row, Ui.button("Apply") { apply })
        Ui.add(row, Ui.button("Close") { close_window(@win) })
        UI.window_set_child(@win, box)
        show_window(@win)
      end

      private

      def pick(index)
        return if index.negative?

        @font = @fonts[index]
        @preview.redraw
      end

      # A few screen-like lines in the chosen font.
      def draw_preview(params)
        pt = @painter
        pt.context = params[:context]
        pt.fill_rect(0, 0, params[:area_width], params[:area_height], BACKGROUND)
        line = FontMetrics.for(@font)[:line] * PREVIEW_SIZE
        SAMPLE.each_with_index do |(text, color, bright), i|
          pt.text(12, 10 + (i * line), -1, text, PALETTE[color], @font, PREVIEW_SIZE, bold: bright)
        end
      end

      def apply
        return if @font.to_s.empty?

        @config["font"] = @font
        @config.save
        @on_change.call
        close_window(@win)
      end
    end
  end
end
