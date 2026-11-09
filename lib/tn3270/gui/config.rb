# frozen_string_literal: true

require "yaml"
require "rbconfig"

module Tn3270
  module Gui
    # Settings live in ~/.ruby3270.yml. Missing keys use these defaults.
    class Config
      WINDOWS = RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/)
      MAC = RbConfig::CONFIG["host_os"].include?("darwin")

      # Screen sizes offered in the connection settings.
      SIZES = [
        ["24 x 80 (Model 2)", 24, 80],
        ["32 x 80 (Model 3)", 32, 80],
        ["43 x 80 (Model 4)", 43, 80],
        ["27 x 132 (Model 5)", 27, 132],
        ["62 x 160 (Large)", 62, 160]
      ].freeze

      DEFAULT_CONNECTION = {
        "name" => "Local fake host", "host" => "127.0.0.1", "port" => 3270, "tls" => false,
        "lu" => "", "rows" => 62, "cols" => 160,
        "verify_cert" => false, # TLS: check the host's certificate (off: self-signed certificates work)
        "script" => "" # Ruby file run each time this connection comes up ("" = none)
      }.freeze

      DEFAULTS = {
        "rows" => 62, # screen size for connections given as plain "host:port"
        "cols" => 160,
        "engine" => nil, # path to s3270 / ws3270.exe; nil = TN3270_ENGINE or PATH
        "font" => WINDOWS ? "Consolas" : MAC ? "Menlo" : "DejaVu Sans Mono",
        "underline_input_fields" => true,
        "poll_ms" => 150,
        "history_size" => 250,
        "typeahead" => true, # queue keys typed while the host is busy
        "numeric_lock" => true, # numeric fields only accept 0-9 . -
        "caps" => false, # the app's own Caps Lock (status bar button); doesn't touch the keyboard's
        "crosshair" => false, # highlight the cursor's row and column
        "spell_check" => true, # Windows: red wavy underline under misspelled words in long input fields
        "spell_min_field" => 20, # ...fields at least this long (shorter ones usually hold codes)
        "spell_language" => nil, # e.g. "en-GB"; nil = the Windows display language
        "spell_ignore" => [], # words never flagged ("Ignore" on the right-click menu adds here)
        "custom_title_bar" => true, # Windows: menus drawn inside the title bar, VS Code style
        "lock_ratio" => true, # Windows: resizing keeps the window the shape of the screen, so there's no empty band
        "key_bar" => false, # the on-screen PF / Reset / Clear... key bar
        "snippet_bar" => false, # the snippets sidebar
        "personal_snippets" => nil, # your snippet file (nil: ~/.ruby3270-snippets.yml)
        "snippet_files" => [], # shared snippet files or folders, e.g. a team file on a network drive
        "snippet_wait_seconds" => 30, # how long {wait:TEXT} in a snippet waits
        "single_instance" => true, # a second launch opens its session as a tab in the running app
        "allow_attach" => true, # let scripts on this computer drive the open session (Tn3270::Session.attach)
        "script_port" => 3271, # ...on this port, on this computer only (127.0.0.1)
        "hide_menu_bar" => false, # without the custom title bar: menus open from the ☰ button in the status bar
        "last_connection" => nil, # name of the connection the status-bar button reconnects to
        "desktop_shortcuts" => true, # Windows: saving a connection puts a shortcut to it on the desktop
        "recent" => [], # connection names, most recently used first (orders the Session menu)
        "welcome_imported" => nil, # the welcome.yml the first launch imported (see SettingsTransfer)
        "keys" => {}, # key binding overrides: { "F13" => "pf13", "Escape" => "" }
        "connections" => [DEFAULT_CONNECTION]
      }.freeze

      PATH = File.join(Dir.home, ".ruby3270.yml")
      OLD_PATH = File.join(Dir.home, ".tn3270-glimmer.yml") # name before the rename; read until the first save

      def self.load(path = PATH)
        from = path == PATH && !File.exist?(path) && File.exist?(OLD_PATH) ? OLD_PATH : path
        user = File.exist?(from) ? (YAML.safe_load_file(from) || {}) : {}
        migrate!(user)
        new(DEFAULTS.merge(user), path)
      end

      # Older configs kept a plain list of "hosts".
      def self.migrate!(user)
        hosts = user.delete("hosts")
        return unless hosts.is_a?(Array) && !user.key?("connections")

        user["connections"] = hosts.map { |h| connection_from_string(h) }
      end

      # "host:port", "L:host:port" (TLS) or "LU@host:port" -> connection hash.
      # A "Y:" prefix (don't verify the certificate) is accepted too; typed
      # connections never verify, like new saved ones.
      def self.connection_from_string(text, rows: DEFAULTS["rows"], cols: DEFAULTS["cols"])
        rest = text.to_s.strip
        tls = false
        while (m = rest.match(/\A([LlYy]):/))
          tls = true if m[1].casecmp?("L")
          rest = m.post_match
        end
        lu, rest = rest.split("@", 2) if rest.include?("@")
        host, port = rest.split(":", 2)
        DEFAULT_CONNECTION.merge("name" => text.to_s.strip, "host" => host.to_s, "port" => (port || 23).to_i,
                                 "tls" => tls, "lu" => lu.to_s, "rows" => rows, "cols" => cols)
      end

      # The string s3270's Connect() action takes. "Y:" tells it not to
      # verify the host's TLS certificate.
      def self.connect_string(conn)
        return display_string(conn) unless conn["tls"] && !conn["verify_cert"]

        "Y:#{display_string(conn)}"
      end

      # "L:LU@host:port", without the "Y:", for menus and messages.
      def self.display_string(conn)
        prefix = conn["tls"] ? "L:" : ""
        lu = conn["lu"].to_s.strip.empty? ? "" : "#{conn['lu'].strip}@"
        "#{prefix}#{lu}#{conn['host'].to_s.strip}:#{conn['port'].to_i}"
      end

      attr_reader :path

      def initialize(values, path)
        @values = values
        @path = path
      end

      def [](key) = @values[key.to_s]

      def []=(key, value)
        @values[key.to_s] = value
      end

      def connections = Array(self["connections"])

      def save
        changed = @values.reject { |k, v| DEFAULTS[k] == v }
        File.write(@path, changed.to_yaml)
      rescue SystemCallError
        nil
      end
    end
  end
end
