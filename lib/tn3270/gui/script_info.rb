# frozen_string_literal: true

module Tn3270
  module Gui
    # The name and description of a script in a script folder, from the
    # comment block at the top of the file:
    #
    #   # Name: Release held jobs
    #   # Releases every held job for your user ID in SDSF.
    #   # Asks nothing; takes about 10 seconds.
    #
    # "Name:" is optional (without it the file name is used: release_held_jobs.rb
    # -> "Release held jobs"). The other comment lines are the description; the
    # first shows under the name in the snippet list, all of them on hover.
    # A first line like #!, "# frozen_string_literal", "# encoding" or
    # "@echo off" is skipped. Comments are # (Ruby, PowerShell, Python),
    # REM or :: (batch), ' (VBScript) or // (JScript).
    module ScriptInfo
      # Script types a folder can hold (the ones StartupScript knows how to run).
      TYPES = %w[.rb .rbw .ps1 .bat .cmd .py .vbs .js].freeze
      MAX_LINES = 10
      HEAD = 40 # lines read from the top of the file

      COMMENT = {
        ".bat" => /\A\s*(?:@?rem\b|::)\s?(.*)\z/i, ".cmd" => /\A\s*(?:@?rem\b|::)\s?(.*)\z/i,
        ".vbs" => /\A\s*(?:'|rem\b)\s?(.*)\z/i, ".js" => %r{\A\s*//\s?(.*)\z}
      }.freeze
      HASH_COMMENT = /\A\s*#\s?(.*)\z/
      SKIP = /\A\s*(?:#!|#\s*(?:frozen_string_literal|encoding|coding|-\*-)|@echo\s+off\b|#requires\b)/i

      module_function

      def script?(path) = TYPES.include?(File.extname(path).downcase)

      # [name, description] for a script file.
      def read(path)
        lines = head(path)
        comment = COMMENT.fetch(File.extname(path).downcase, HASH_COMMENT)
        lines = lines.drop_while { |l| l.strip.empty? || l.match?(SKIP) }
        block = lines.take_while { |l| l.match?(comment) }.map { |l| l[comment, 1].to_s.rstrip }
        name = nil
        about = block.reject do |l|
          next false unless (m = l.match(/\A\s*name:\s*(.+)\z/i))

          name ||= m[1].strip
          true
        end
        about = about.drop_while(&:empty?).first(MAX_LINES)
        about.pop while about.last&.empty?
        [name || name_from_file(path), about.join("\n")]
      end

      # release_held_jobs.rb -> "Release held jobs"
      def name_from_file(path)
        words = File.basename(path, ".*").tr("_-", "  ").squeeze(" ").strip
        words.empty? ? File.basename(path) : words[0].upcase + words[1..]
      end

      def head(path)
        File.foreach(path, encoding: "BOM|UTF-8").first(HEAD).map { |l| l.scrub.chomp }
      rescue SystemCallError, ArgumentError
        []
      end
    end
  end
end
