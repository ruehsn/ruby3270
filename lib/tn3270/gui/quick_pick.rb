# frozen_string_literal: true

module Tn3270
  module Gui
    # What the quick picker (Ctrl+Space) lists: commands such as Stop Script,
    # the on/off settings and the snippets, with the last few picks first when
    # nothing is typed yet. Kept apart from the drawing so it can be tested.
    module QuickPick
      RECENT_MAX = 5

      # A command the picker can run (not a setting, not a snippet).
      Command = Struct.new(:name, :label, :words, :detail)

      COMMANDS = [
        Command.new(:stop_scripts, "Stop Script", "stop scripts kill cancel end abort",
                    "Stops the scripts running on this tab")
      ].freeze

      # The commands whose label (or extra words) has every word of `query`.
      def self.match_commands(query, commands = COMMANDS)
        words = query.to_s.downcase.split
        return [] if words.empty?

        commands.select do |c|
          hay = "#{c.label} #{c.words}".downcase
          words.all? { |w| hay.include?(w) }
        end
      end

      # The key a pick is remembered by: "command:stop_scripts",
      # "setting:caps", "snippet:Sign on".
      def self.key_of(item)
        case item
        when Command then "command:#{item.name}"
        when Program::Toggle then "setting:#{item.name}"
        else "snippet:#{item.name}"
        end
      end

      # `recent` with `item` moved to the front, at most RECENT_MAX long.
      def self.remember(recent, item)
        key = key_of(item)
        ([key] + Array(recent).reject { |k| k == key }).first(RECENT_MAX)
      end

      # The picker's rows. With a query: matching commands, settings, then
      # snippets. Without: Stop Script while a script is busy, then the recent
      # picks that still exist, then the rest of the snippets.
      #   toggles: every setting; matched_toggles: those matching the query
      #   snippets: library.search(query)
      def self.items(query:, toggles:, matched_toggles:, snippets:, recent:, busy:, limit:)
        unless query.to_s.strip.empty?
          return (match_commands(query) + matched_toggles + snippets).first(limit)
        end

        pool = COMMANDS + toggles + snippets
        by_key = {}
        pool.each { |item| by_key[key_of(item)] ||= item }
        first = busy ? [by_key["command:stop_scripts"]] : []
        recents = Array(recent).filter_map { |k| by_key[k] }
        (first + recents + snippets).uniq.first(limit)
      end

      # Whether `item` (a picker row) is one of the recent picks.
      def self.recent?(item, recent) = Array(recent).include?(key_of(item))
    end
  end
end
