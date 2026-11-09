# frozen_string_literal: true

require "set"

module Tn3270
  module Gui
    # Finds misspelled words in a screen's input fields. The checker does the
    # spelling (SpellChecker on Windows, or anything with correct?/suggest);
    # this class decides what counts as a word worth checking:
    #
    #   - only input fields at least `min_field` long (free-text fields, not
    #     short code fields), never hidden ones (passwords)
    #   - only plain words of 3+ letters: SYS1.PROCLIB, IEF142I and &SYSUID
    #     are left alone
    #   - ALL-CAPS words (usual on a mainframe) are checked like ordinary
    #     words: TEH is flagged, LONDON passes as London. Acronyms like JCL
    #     get flagged too; Ignore or Add them once
    #   - words on the ignore list (any case)
    class Spelling
      # A misspelled word: where it starts, the word, and its field.
      Word = Struct.new(:row, :col, :text, :field, keyword_init: true)

      # Leading / trailing punctuation that doesn't stop a word counting.
      LEAD = /\A[("'\[]+/
      TRAIL = /[)"'\].,;:!?]+\z/
      PLAIN = /\A[[:alpha:]]+(?:'[[:alpha:]]+)?\z/

      attr_reader :checker
      attr_accessor :min_field

      def initialize(checker, min_field: 20, ignored: [])
        @checker = checker
        @min_field = min_field
        @ignored = ignored.to_set { |w| w.downcase }
        @known = {}
        @memo = nil
      end

      def ignore(word)
        @ignored << word.downcase
        @memo = nil
      end

      # After words were added to the checker's dictionary.
      def forget
        @known.clear
        @memo = nil
      end

      def ignored?(word) = @ignored.include?(word.downcase)

      # Every misspelled word on the screen, in screen order. Remembers the
      # answer for the last screen object, so it's cheap to call per frame.
      def misspelled(screen)
        return [] unless screen
        return @memo[1] if @memo && @memo[0].equal?(screen)

        words = checked_fields(screen).flat_map { |f| misspelled_in(f, screen.cols, screen.rows) }
        @memo = [screen, words]
        words
      end

      # The misspelled word covering a cell, or nil.
      def word_at(screen, row, col)
        misspelled(screen).find { |w| cells(w, screen.cols, screen.rows).include?([row, col]) }
      end

      # Suggestions in the word's own case (TEH -> THE, Teh -> The).
      def suggest(word)
        list = if all_caps?(word)
                 @checker.suggest(word.downcase).map(&:upcase)
               else
                 @checker.suggest(word).map { |s| word.match?(/\A[[:upper:]]/) ? s.sub(/\A./, &:upcase) : s }
               end
        list.uniq.reject { |s| s == word }
      end

      # The [row, col] cells a word covers (a word can wrap onto the next row).
      def cells(word, cols, rows)
        start = (word.row * cols) + word.col
        Array.new(word.text.size) { |i| ((start + i) % (rows * cols)).divmod(cols) }
      end

      # Words in a field's text, as [offset, word].
      def self.words(value)
        value.to_enum(:scan, /\S+/).filter_map do
          token = Regexp.last_match[0]
          offset = Regexp.last_match.begin(0)
          lead = token[LEAD].to_s.size
          word = token[lead..].sub(TRAIL, "")
          [offset + lead, word] if word.size >= 3 && word.match?(PLAIN)
        end
      end

      private

      def checked_fields(screen)
        screen.fields.select { |f| f.input? && !f.hidden && f.length >= @min_field }
      end

      def misspelled_in(field, cols, rows)
        value = field.value.to_s
        start = (field.row * cols) + field.col
        Spelling.words(value).filter_map do |offset, word|
          next if ignored?(word) || correct?(word)

          row, col = ((start + offset) % (rows * cols)).divmod(cols)
          Word.new(row: row, col: col, text: word, field: field)
        end
      end

      def correct?(word)
        @known.fetch(word) do
          @known[word] =
            if all_caps?(word)
              lower = word.downcase
              @checker.correct?(lower) || @checker.correct?(lower.capitalize)
            else
              @checker.correct?(word)
            end
        end
      end

      def all_caps?(word) = word.match?(/[[:upper:]]/) && !word.match?(/[[:lower:]]/)
    end
  end
end
