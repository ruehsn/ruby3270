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
    #   - only plain words of `min_word`+ letters (short ones are mostly
    #     codes): SYS1.PROCLIB, IEF142I and &SYSUID are left alone
    #   - ALL-CAPS words (usual on a mainframe) are checked like ordinary
    #     words: TEH is flagged, LONDON passes as London. Acronyms like JCL
    #     get flagged too; Ignore or Add them once
    #   - words on the ignore list (any case), and words that fit a pattern
    #     on it (see WordPattern): AC?????? skips every 8-letter word
    #     starting with AC
    class Spelling
      # A misspelled word: where it starts, the word, and its field.
      Word = Struct.new(:row, :col, :text, :field, keyword_init: true)

      # Leading / trailing punctuation that doesn't stop a word counting.
      LEAD = /\A[("'\[]+/
      TRAIL = /[)"'\].,;:!?]+\z/
      PLAIN = /\A[[:alpha:]]+(?:'[[:alpha:]]+)?\z/

      attr_reader :checker, :min_field, :min_word

      def initialize(checker, min_field: 20, min_word: 3, ignored: [])
        @checker = checker
        @min_field = min_field
        @min_word = min_word
        self.ignored = ignored
        @known = {}
        @memo = nil
      end

      # Shortest input field that gets checked.
      def min_field=(length)
        @memo = nil unless length == @min_field
        @min_field = length
      end

      # Shortest word that gets checked.
      def min_word=(length)
        @memo = nil unless length == @min_word
        @min_word = length
      end

      def ignore(word)
        @ignored << word.downcase
        @memo = nil
      end

      # Replaces the whole ignore list (after a word list file changed).
      # Entries with ? or * in them are patterns, the rest plain words.
      def ignored=(words)
        patterns, plain = words.partition { |w| WordPattern.pattern?(w) }
        @ignored = plain.to_set(&:downcase)
        @patterns = patterns.map { |p| WordPattern.new(p) }
        @memo = nil
      end

      # After words were added to the checker's dictionary.
      def forget
        @known.clear
        @memo = nil
      end

      def ignored?(word) = @ignored.include?(word.downcase) || @patterns.any? { |p| p.match?(word) }

      # Every misspelled word on the screen, in screen order. Remembers the
      # answer for the last screen's fields, so it's cheap to call per frame
      # (a cursor move gives a new Screen with the same fields).
      def misspelled(screen)
        return [] unless screen
        return @memo[1] if @memo && @memo[0].equal?(screen.fields)

        words = checked_fields(screen).flat_map { |f| misspelled_in(f, screen.cols, screen.rows) }
        @memo = [screen.fields, words]
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
      def self.words(value, min: 3)
        value.to_enum(:scan, /\S+/).filter_map do
          token = Regexp.last_match[0]
          offset = Regexp.last_match.begin(0)
          lead = token[LEAD].to_s.size
          word = token[lead..].sub(TRAIL, "")
          [offset + lead, word] if word.size >= min && word.match?(PLAIN)
        end
      end

      private

      def checked_fields(screen)
        screen.fields.select { |f| f.input? && !f.hidden && f.length >= @min_field }
      end

      def misspelled_in(field, cols, rows)
        value = field.value.to_s
        start = (field.row * cols) + field.col
        Spelling.words(value, min: [@min_word.to_i, 1].max).filter_map do |offset, word|
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

    # A word pattern from a spelling word list, matched letter by letter (no
    # regular expressions, so a pattern can't do anything surprising):
    #
    #   ?   any one letter          AC??????  8 letters starting with AC
    #   *   any letters, or none    AH*       anything starting with AH
    #                               *ING      anything ending in ING
    #
    # Case doesn't matter. Anything else must match itself.
    class WordPattern
      def self.pattern?(text) = text.include?("?") || text.include?("*")

      def initialize(text)
        @chars = text.downcase.chars
      end

      # Two pointers, going back to the last * on a mismatch: linear-ish,
      # never exponential, whatever the pattern.
      def match?(word)
        w = word.downcase.chars
        p = 0
        i = 0
        star = nil
        mark = 0
        while i < w.size
          if p < @chars.size && (@chars[p] == "?" || @chars[p] == w[i])
            p += 1
            i += 1
          elsif p < @chars.size && @chars[p] == "*"
            star = p
            mark = i
            p += 1
          elsif star
            p = star + 1
            mark += 1
            i = mark
          else
            return false
          end
        end
        p += 1 while p < @chars.size && @chars[p] == "*"
        p == @chars.size
      end
    end
  end
end
