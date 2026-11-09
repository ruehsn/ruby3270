# frozen_string_literal: true

require "yaml"
require "time"
require_relative "config"

module Tn3270
  module Gui
    # Session > Export Settings / Import Settings: your sessions, your own
    # snippets and your options in one YAML file, to move to a new PC or hand
    # to a colleague. Things that only make sense on this computer (recently
    # used sessions, the engine's path...) stay behind.
    #
    # Importing merges: sessions and snippets with the same name are replaced,
    # everything else you have is kept; the file's options replace yours.
    module SettingsTransfer
      MARK = "ruby3270_settings"
      FORMAT = 1
      # Never exported, never imported.
      LOCAL = %w[recent last_connection engine personal_snippets connections welcome_imported].freeze

      module_function

      # The file's contents for `config` and your own snippets (`items`: name/text).
      def export(config, items)
        options = Config::DEFAULTS.keys.each_with_object({}) do |key, h|
          next if LOCAL.include?(key) || config[key] == Config::DEFAULTS[key]

          h[key] = config[key]
        end
        {
          MARK => FORMAT,
          "exported" => Time.now.iso8601,
          "options" => options,
          "connections" => config.connections.map(&:dup),
          "snippets" => items.map { |i| { "name" => i.name.to_s, "text" => i.text.to_s } }
        }
      end

      def write(path, bundle) = File.write(path, bundle.to_yaml)

      # Reads and checks an exported file. Raises ArgumentError if it isn't one.
      def read(path)
        data = YAML.safe_load_file(path)
        raise ArgumentError, "This isn't a ruby3270 settings file." unless data.is_a?(Hash) && data[MARK]
        raise ArgumentError, "This file is from a newer ruby3270; update first." if data[MARK].to_i > FORMAT

        {
          "options" => (data["options"].is_a?(Hash) ? data["options"] : {}).reject { |k, _| LOCAL.include?(k) },
          "connections" => Array(data["connections"]).select { |c| c.is_a?(Hash) && !c["name"].to_s.strip.empty? },
          "snippets" => Array(data["snippets"]).select { |s| s.is_a?(Hash) && !s["name"].to_s.strip.empty? }
        }
      end

      # "3 sessions, 12 snippets and 4 options", for the confirm message.
      def summary(bundle)
        parts = [count(bundle["connections"].size, "session"), count(bundle["snippets"].size, "snippet"),
                 count(bundle["options"].size, "option")]
        "#{parts[0..-2].join(', ')} and #{parts[-1]}"
      end

      def count(n, word) = "#{n} #{word}#{'s' unless n == 1}"

      # ---- welcome.yml: settings for a first launch ------------------------------------
      # An exported settings file that a new user's first launch imports, so a
      # team can hand out ruby3270 with its sessions and snippets set up. It's
      # looked for outside the program folder first, so updating the program
      # (a new zip, a git pull) never removes or replaces it:
      #   1. the file named by the RUBY3270_WELCOME environment variable
      #      (e.g. on a network share, set by IT)
      #   2. %ProgramData%\ruby3270\welcome.yml (shared by everyone on the PC)
      #   3. welcome.yml in the program folder
      # It's only used when there are no settings yet, so it never overwrites
      # what someone has changed; the settings remember which file it was.

      PROGRAM_DIR = File.expand_path("../../..", __dir__)

      def welcome_paths(env = ENV, program_dir: PROGRAM_DIR)
        [env["RUBY3270_WELCOME"].to_s.strip,
         env["ProgramData"] && File.join(env["ProgramData"], "ruby3270", "welcome.yml"),
         File.join(program_dir, "welcome.yml")].compact.reject(&:empty?)
      end

      def find_welcome(paths = welcome_paths) = paths.find { |p| File.file?(p) }

      # On a first launch (`first`: no settings file yet), imports the welcome
      # file if there is one, and saves. Returns the path imported, or nil.
      # A broken welcome file is skipped (the app starts as usual).
      def welcome(config, library, first:, paths: welcome_paths)
        return nil unless first && (path = find_welcome(paths))

        bundle = read(path)
        config["connections"] = [] if bundle["connections"].any? # the team's sessions instead of the demo one
        snippets = apply(bundle, config)
        config["welcome_imported"] = path
        config.save
        merge_snippets(library, snippets)
        path
      rescue ArgumentError, Psych::Exception, SystemCallError => e
        warn "welcome settings #{path}: #{e.message}"
        nil
      end

      # Adds snippets to your own file, replacing ones with the same name.
      def merge_snippets(library, snippets)
        return if snippets.empty?

        library.reload_if_changed
        file = library.personal_file
        mine = library.items.select { |i| i.file == file }
        snippets.each do |s|
          name = s["name"].to_s.strip
          existing = mine.find { |i| i.name.strip.casecmp?(name) }
          library.save(existing, name, s["text"].to_s, file)
        end
      end

      # Merges a read bundle into `config` (not saved: the caller saves).
      # Returns the snippets to add or replace in your own file.
      def apply(bundle, config)
        bundle["options"].each do |key, value|
          config[key] = case key
                        when "spell_ignore", "snippet_files" then (Array(config[key]) + Array(value)).uniq
                        when "keys" then (config["keys"] || {}).merge(value.is_a?(Hash) ? value : {})
                        else value
                        end
        end
        incoming = bundle["connections"].map { |c| Config::DEFAULT_CONNECTION.merge(c) }
        names = incoming.map { |c| c["name"].to_s.strip.downcase }
        kept = config.connections.reject { |c| names.include?(c["name"].to_s.strip.downcase) }
        config["connections"] = kept + incoming
        bundle["snippets"]
      end
    end
  end
end
