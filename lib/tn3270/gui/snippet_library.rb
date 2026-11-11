# frozen_string_literal: true

require "yaml"
require "fileutils"
require_relative "config"
require_relative "script_info"

module Tn3270
  module Gui
    # The snippets, from several files: your own (`personal_snippets`,
    # ~/.ruby3270-snippets.yml by default) and any shared ones listed in
    # `snippet_files` (files, or folders of *.yml files), e.g. a team file on
    # a network drive. Each file is a YAML list:
    #
    #   - name: Data set list
    #     text: "=3.4{Enter}"
    #
    # New snippets go to whichever file you pick (your own by default).
    # Shared files you can't write to are read-only here.
    #
    # The folders in `script_folders` add their scripts (Ruby, PowerShell,
    # batch...) to the list: the name and description come from each
    # script's header comments (see ScriptInfo), and picking one runs it
    # against the current session (see Controller#run_script).
    class SnippetLibrary
      PERSONAL = File.join(Dir.home, ".ruby3270-snippets.yml")

      # `script` is the script's path for an item from a script folder (its
      # text is then the description); nil for a snippet.
      Item = Struct.new(:name, :text, :file, :script) do
        def script? = !script.nil?
      end

      attr_reader :items, :errors

      def initialize(config)
        @config = config
        @items = []
        @errors = []
        @stamps = nil
      end

      def personal_file = (@config["personal_snippets"].to_s.empty? ? PERSONAL : File.expand_path(@config["personal_snippets"]))

      # Shared entries as given in the config (files or folders).
      def shared_entries = Array(@config["snippet_files"]).map(&:to_s).reject(&:empty?)

      # Every file snippets come from: yours first, then the shared ones.
      def files
        shared = shared_entries.flat_map do |entry|
          path = File.expand_path(entry)
          File.directory?(path) ? Dir.glob(File.join(path, "*.{yml,yaml}")).sort : [path]
        end
        ([personal_file] + shared).uniq
      end

      def script_folders = Array(@config["script_folders"]).map(&:to_s).reject(&:empty?)

      # Every script in the script folders, by file name within each folder.
      def script_files
        script_folders.flat_map do |entry|
          dir = File.expand_path(entry)
          next [] unless File.directory?(dir)

          Dir.children(dir).select { |n| ScriptInfo.script?(n) }.sort_by(&:downcase)
             .map { |n| File.join(dir, n) }.select { |p| File.file?(p) }
        rescue SystemCallError
          []
        end.uniq
      end

      # Loads (again) when any file has changed since the last load.
      def reload_if_changed
        stamps = (files + script_files).map { |f| [f, File.exist?(f) ? File.mtime(f) : nil] }
        return false if stamps == @stamps

        @stamps = stamps
        load_all
        true
      end

      def load_all
        @errors = []
        @items = files.flat_map { |f| read(f) } + script_files.map { |f| script_item(f) }
      end

      def script_item(path)
        name, about = ScriptInfo.read(path)
        Item.new(name, about, path, path)
      end

      # Adds a script folder to the config (saved by the caller).
      def add_script_folder(path)
        @config["script_folders"] = (script_folders + [path]).uniq
        @stamps = nil
      end

      def remove_script_folder(path)
        @config["script_folders"] = script_folders - [path]
        @stamps = nil
      end

      # Items whose name or text contains every word of `query`, names that
      # start with the query first.
      def search(query)
        words = query.to_s.downcase.split
        found = @items.select do |item|
          hay = "#{item.name}\n#{item.text}".downcase
          words.all? { |w| hay.include?(w) }
        end
        q = query.to_s.downcase.strip
        found.sort_by.with_index { |item, i| [item.name.downcase.start_with?(q) ? 0 : 1, i] }
      end

      def writable?(file)
        return false if ScriptInfo.script?(file) # a script, never written as a snippet file
        return File.writable?(file) if File.exist?(file)

        dir = File.dirname(file)
        File.directory?(dir) ? File.writable?(dir) : file == personal_file
      end

      def writable_files = files.select { |f| writable?(f) }

      # Saves a new or changed snippet. `item` is nil for a new one. Moving a
      # snippet to another file takes it out of the old one.
      def save(item, name, text, file)
        old_file = item&.file
        if item
          item.name = name
          item.text = text
          item.file = file
        else
          @items << Item.new(name, text, file)
        end
        write(file)
        write(old_file) if old_file && old_file != file
      end

      def delete(item)
        @items.delete(item)
        write(item.file)
      end

      # Adds a shared file or folder to the config (saved by the caller).
      def add_shared(path)
        @config["snippet_files"] = (shared_entries + [path]).uniq
        @stamps = nil
      end

      def remove_shared(path)
        @config["snippet_files"] = shared_entries - [path]
        @stamps = nil
      end

      # Creates an empty snippet file (for a new shared file).
      def self.create_file(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "# ruby3270 snippets: a list of name / text pairs\n[]\n") unless File.exist?(path)
      end

      private

      def read(file)
        return [] unless File.exist?(file)

        data = YAML.safe_load_file(file) || []
        raise "not a list" unless data.is_a?(Array)

        data.filter_map do |entry|
          next unless entry.is_a?(Hash) && entry["name"].to_s.strip != ""

          Item.new(entry["name"].to_s, entry["text"].to_s, file)
        end
      rescue StandardError => e
        @errors << "#{File.basename(file)}: #{e.message.lines.first.strip}"
        []
      end

      def write(file)
        entries = @items.select { |i| i.file == file && !i.script? }.map { |i| { "name" => i.name, "text" => i.text } }
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, entries.to_yaml)
        @stamps = nil
      end
    end
  end
end
