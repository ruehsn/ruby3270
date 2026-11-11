# frozen_string_literal: true

module Tn3270
  module Gui
    # Words spell check never flags, from word list files (one word per line;
    # blank lines and lines starting with # are skipped; any words on a line
    # count). They are read at launch and again whenever one of the files
    # changes, so editing a file (yours or a shared one) takes effect at once:
    #
    #   1. mainframe_words.txt in this folder: comes with the program (JCL,
    #      TSO, ISPF, CICS, DB2 terms...) and is refreshed by updates
    #   2. your own list, ~/.ruby3270-spelling.txt (right-click > Ignore adds
    #      to it; View > Edit My Spelling Words opens it)
    #   3. spelling.txt in %ProgramData%\ruby3270 or the program folder:
    #      a company's own list, which program updates never touch
    #   4. the files in the spell_word_files setting, e.g. a team list on a
    #      network drive
    module SpellWords
      BUILT_IN = File.expand_path("mainframe_words.txt", __dir__)
      PROGRAM_DIR = File.expand_path("../../..", __dir__)
      FILE_NAME = "spelling.txt"
      PERSONAL = File.join(Dir.home, ".ruby3270-spelling.txt")
      HEADER = <<~TEXT
        # Your words spell check never flags. Right-click > Ignore adds to this file;
        # edit it in any text editor. One or more words per line; # starts a comment.
        # Share it by copying it, or list a shared copy in spell_word_files.
      TEXT

      # Your own list (the personal_spelling setting moves it).
      def self.personal_file(config)
        path = config["personal_spelling"].to_s
        path.empty? ? PERSONAL : File.expand_path(path)
      end

      def self.paths(config, env: ENV, program_dir: PROGRAM_DIR)
        site = [env["ProgramData"] && File.join(env["ProgramData"], "ruby3270", FILE_NAME),
                File.join(program_dir, FILE_NAME)].compact
        [BUILT_IN, personal_file(config), *site,
         *Array(config["spell_word_files"]).map { |f| File.expand_path(f.to_s) }].uniq
      end

      # Every word from the files that exist; a missing or unreadable file is skipped.
      def self.load(config, **opts)
        paths(config, **opts).flat_map { |path| read(path) }.uniq
      end

      # Changes when any of the files is added, removed or saved.
      def self.stamp(config, **opts)
        paths(config, **opts).map { |p| File.file?(p) ? [File.mtime(p), File.size(p)] : nil }
      rescue SystemCallError
        nil
      end

      def self.read(path)
        return [] unless File.file?(path)

        File.readlines(path, encoding: "UTF-8", chomp: true)
            .reject { |l| l.strip.empty? || l.lstrip.start_with?("#") }
            .flat_map(&:split).map(&:downcase)
      rescue SystemCallError, ArgumentError
        []
      end

      # The words in your own list.
      def self.personal(config) = read(personal_file(config))

      # Adds words to the end of your own list (made if missing), skipping
      # ones already in it. Returns the words added.
      def self.add(config, words)
        path = personal_file(config)
        have = personal(config)
        new_words = Array(words).map { |w| w.to_s.strip.downcase }.reject(&:empty?).uniq - have
        return [] if new_words.empty?

        text = File.file?(path) ? File.read(path, encoding: "UTF-8") : HEADER
        text += "\n" unless text.empty? || text.end_with?("\n")
        File.write(path, text + new_words.map { |w| "#{w}\n" }.join)
        new_words
      rescue SystemCallError
        []
      end

      # Older versions kept your list in the settings (spell_ignore): moves it
      # to your file and takes it out of the settings.
      def self.migrate(config)
        old = Array(config["spell_ignore"])
        return if old.empty?

        add(config, old)
        config["spell_ignore"] = nil
        config.save if config.respond_to?(:save)
      end

      # Makes your file if it isn't there yet, and returns its path.
      def self.ensure_personal(config)
        path = personal_file(config)
        File.write(path, HEADER) unless File.exist?(path)
        path
      end
    end
  end
end
