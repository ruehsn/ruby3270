# frozen_string_literal: true

module Tn3270
  module Gui
    # Turns a libui key event (a Hash from Ui::Area) into an action, using a table of key bindings
    # ("Shift+F1" => "pf13"). Users can override any binding; overrides are
    # stored in the config under "keys", and "" there unbinds a default.
    #
    # translate returns one of:
    #   [:key, :pf13]                  an AID or editing key for Session#press
    #   [:type, "a"]                   a character to type
    #   [:copy] / [:paste]             clipboard
    #   [:history]                     open the screen history window
    #   nil                            not ours; let it pass through
    module Keymap
      module_function

      # LibUI reports the unshifted key plus a :shift modifier, so printable
      # characters are shifted here. This table is the US layout.
      SHIFTED = {
        "1" => "!", "2" => "@", "3" => "#", "4" => "$", "5" => "%", "6" => "^", "7" => "&",
        "8" => "*", "9" => "(", "0" => ")", "-" => "_", "=" => "+", "[" => "{", "]" => "}",
        "\\" => "|", ";" => ":", "'" => '"', "," => "<", "." => ">", "/" => "?", "`" => "~"
      }.freeze

      KEYPAD = {
        n0: "0", n1: "1", n2: "2", n3: "3", n4: "4", n5: "5", n6: "6", n7: "7", n8: "8", n9: "9",
        n_dot: ".", n_add: "+", n_subtract: "-", n_multiply: "*", n_divide: "/"
      }.freeze

      # LibUI extended key -> name used in bindings.
      EXT_NAMES = {
        escape: "Escape", insert: "Insert", delete: "Delete", home: "Home", end: "End",
        page_up: "PageUp", page_down: "PageDown", up: "Up", down: "Down", left: "Left", right: "Right",
        n_enter: "Keypad Enter"
      }.merge((1..12).to_h { |n| [:"f#{n}", "F#{n}"] })
       .merge(KEYPAD.to_h { |k, ch| [k, "Keypad #{ch}"] })
       .freeze

      CODE_NAMES = { 8 => "Backspace", 9 => "Tab", 10 => "Enter", 13 => "Enter", 27 => "Escape",
                     32 => "Space", 127 => "Delete" }.freeze

      # Every action a key can be bound to, with its label for menus and help.
      ACTIONS = {
        "enter" => "Enter", "clear" => "Clear", "reset" => "Reset (unlock)",
        "escape" => "Reset if the keyboard is locked, otherwise Clear",
        "attn" => "Attn", "sysreq" => "SysReq",
        **(1..24).to_h { |n| ["pf#{n}", "PF#{n}"] },
        **(1..3).to_h { |n| ["pa#{n}", "PA#{n}"] },
        "tab" => "Next field", "backtab" => "Previous field", "home" => "First input field",
        "newline" => "New line", "erase_eof" => "Erase to end of field",
        "erase_input" => "Erase all input", "backspace" => "Backspace", "delete" => "Delete",
        "insert" => "Toggle insert mode",
        "up" => "Cursor up", "down" => "Cursor down", "left" => "Cursor left", "right" => "Cursor right",
        "copy" => "Copy", "paste" => "Paste",
        "history" => "Screen history window",
        "find" => "Find on screen / in history",
        "crosshair" => "Crosshair on/off",
        "caps" => "Caps Lock (this app only) on/off",
        "snippet_picker" => "Snippets: quick pick",
        "snippet_bar" => "Snippets sidebar on/off",
        "spell_next" => "Next misspelled word (opens its suggestions)",
        "new_tab" => "New tab", "close_tab" => "Close tab", "new_window" => "New window",
        "next_tab" => "Next tab", "prev_tab" => "Previous tab",
        **(1..9).to_h { |n| ["snippet#{n}", "Snippet #{n} (in the sidebar list)"] }
      }.freeze

      # Detects a modifier pressed and released on its own ("Right Ctrl").
      # LibUI doesn't say which side was pressed, so `side` is asked at
      # key-down (it returns :left, :right or nil); with no answer, taps
      # aren't reported. Pressing any other key in between cancels the tap,
      # so Right Ctrl+C still copies.
      class ModifierTap
        NAMES = { control: "Ctrl", alt: "Alt", shift: "Shift" }.freeze

        def initialize(&side)
          @side = side
          @pending = nil
        end

        # Feed every key event; returns the tap's chord name on release.
        def feed(event)
          mod = event[:modifier]
          unless mod && NAMES[mod] && event[:key_value].to_i.zero? && event[:ext_key].nil?
            @pending = nil
            return nil
          end

          if event[:up]
            chord = @pending if @pending_mod == mod
            @pending = nil
            chord
          else
            side = @side&.call(mod)
            @pending_mod = mod
            @pending = side ? "#{side == :right ? 'Right' : 'Left'} #{NAMES[mod]}" : nil
            nil
          end
        end
      end

      DEFAULTS = {
        **(1..12).to_h { |n| ["F#{n}", "pf#{n}"] },
        **(1..12).to_h { |n| ["Shift+F#{n}", "pf#{n + 12}"] },
        **(1..3).to_h { |n| ["Ctrl+F#{n}", "pa#{n}"] },
        "Enter" => "enter", "Keypad Enter" => "enter", "Shift+Enter" => "newline", "Right Ctrl" => "newline",
        "Escape" => "escape", "Ctrl+R" => "reset", "Ctrl+A" => "attn",
        "Tab" => "tab", "Shift+Tab" => "backtab", "Home" => "home", "End" => "erase_eof",
        "Insert" => "insert", "Delete" => "delete", "Backspace" => "backspace",
        "Up" => "up", "Down" => "down", "Left" => "left", "Right" => "right",
        "Ctrl+C" => "copy", "Ctrl+V" => "paste",
        "Ctrl+H" => "history", "Ctrl+PageUp" => "history",
        "Ctrl+F" => "find", "Ctrl+Shift+X" => "crosshair",
        "Ctrl+Space" => "snippet_picker", "Ctrl+Shift+S" => "snippet_bar", "Ctrl+;" => "spell_next",
        "Ctrl+T" => "new_tab", "Ctrl+W" => "close_tab", "Ctrl+N" => "new_window",
        "Ctrl+Tab" => "next_tab", "Ctrl+Shift+Tab" => "prev_tab",
        **(1..9).to_h { |n| ["Ctrl+#{n}", "snippet#{n}"] }
      }.freeze

      # Effective bindings: defaults with the user's overrides on top.
      # Overrides naming an unknown action are ignored.
      def bindings(overrides = {})
        DEFAULTS.merge(overrides || {}).select { |_, action| ACTIONS.key?(action.to_s) }
      end

      # Chords bound to an action, e.g. keys_for(b, "pf13") => ["Shift+F1"]
      def keys_for(bindings, action) = bindings.select { |_, a| a == action }.keys

      # Name of the key combination in an event ("Ctrl+Shift+F1"), or nil for
      # a bare modifier press.
      def chord(event)
        name = key_name(event)
        return nil unless name

        mods = Array(event[:modifiers])
        prefix = []
        prefix << "Ctrl" if mods.include?(:ctrl) || mods.include?(:control)
        prefix << "Alt" if mods.include?(:alt)
        prefix << "Shift" if mods.include?(:shift)
        prefix << "Cmd" if mods.include?(:command)
        (prefix << name).join("+")
      end

      def key_name(event)
        ext = event[:ext_key]
        return EXT_NAMES[ext] if ext && EXT_NAMES[ext]

        code = (event[:key_value] || event[:key].to_s.ord).to_i
        return CODE_NAMES[code] if CODE_NAMES[code]
        return nil if code < 32

        code.chr(Encoding::UTF_8).upcase
      rescue RangeError
        nil
      end

      def translate(event, bindings = DEFAULTS)
        return nil if event[:up]

        name = chord(event)
        if name && (action = bindings[name])
          return action_result(action)
        end

        mods = Array(event[:modifiers])
        return nil if mods.intersect?(%i[ctrl control alt command])

        ext = event[:ext_key]
        return [:type, KEYPAD[ext]] if ext && KEYPAD[ext]
        return nil if ext

        key = event[:key].to_s
        return nil if key.empty? || key.ord < 32 || key.ord == 127

        shift = mods.include?(:shift)
        [:type, shift ? (SHIFTED[key] || key.upcase) : key]
      end

      def action_result(action)
        case action
        when "copy" then [:copy]
        when "paste" then [:paste]
        when "history" then [:history]
        when "find" then [:find]
        when "crosshair" then [:crosshair]
        when "caps" then [:caps]
        when "snippet_picker" then [:snippet_picker]
        when "snippet_bar" then [:snippet_bar]
        when "spell_next" then [:spell_next]
        when "new_tab", "close_tab", "new_window", "next_tab", "prev_tab" then [action.to_sym]
        when /\Asnippet(\d)\z/ then [:snippet, Regexp.last_match(1).to_i]
        else [:key, action.to_sym]
        end
      end

      # Shown in Help > Keyboard.
      def help(bindings)
        ACTIONS.filter_map do |action, label|
          keys = keys_for(bindings, action)
          next if keys.empty?

          format("%-30s %s", keys.join(", "), label)
        end.join("\n") + "\n#{format('%-30s %s', 'Click / drag', 'Move cursor / select text')}" \
                         "\n#{format('%-30s %s', 'Right-click', 'Copy the selection; on a red-underlined word, spelling suggestions')}"
      end
    end
  end
end
