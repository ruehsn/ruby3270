# frozen_string_literal: true

require_relative "spelling"
require_relative "spell_checker"
require_relative "spell_words"
require_relative "win32"

module Tn3270
  module Gui
    # Spell checking in the main window (mixed into TerminalWindow): red wavy underlines
    # under misspelled words in long input fields, a right-click menu of
    # suggestions, and Ctrl+; to jump to the next misspelled word.
    # Windows only: elsewhere `spelling` is nil and none of this shows.
    module SpellUi
      SQUIGGLE = [0xFF, 0x4D, 0x4D].freeze
      MAX_SUGGESTIONS = 5
      WORDS_CHECK_SECONDS = 2

      # The Spelling for the current settings, or nil (off, or no checker).
      # Made on first use, on the main thread (the checker is a COM object).
      def spelling
        return nil unless @config["spell_check"]

        key = @config["spell_language"]
        unless @spelling_for == [key]
          @spelling_for = [key]
          SpellWords.migrate(@config)
          checker = SpellChecker.open(key)
          @words_stamp = SpellWords.stamp(@config)
          @words_checked = monotonic_now
          @spelling = checker && Spelling.new(checker, min_field: @config["spell_min_field"].to_i,
                                                       ignored: SpellWords.load(@config))
        end
        reload_spell_words if @spelling
        @spelling&.min_field = @config["spell_min_field"].to_i
        @spelling
      end

      # Picks up edits to the word list files (looked at every few seconds,
      # since a shared one may be on a slow network drive).
      def reload_spell_words(force: false)
        now = monotonic_now
        return unless force || now - @words_checked.to_f >= WORDS_CHECK_SECONDS

        @words_checked = now
        stamp = SpellWords.stamp(@config)
        return if stamp == @words_stamp && !force

        @words_stamp = stamp
        @spelling.ignored = SpellWords.load(@config)
      end

      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # View > Edit My Spelling Words...: your word list in a text editor.
      # Saved changes show the next time the screen is checked.
      def edit_spell_words
        open_in_editor(SpellWords.ensure_personal(@config))
      end

      # A text file (word list, script) in a text editor (Notepad on Windows).
      def open_in_editor(path)
        cmd = if Config::WINDOWS then ["notepad.exe", path]
              elsif Config::MAC then ["open", "-t", path]
              else ["xdg-open", path]
              end
        Process.detach(Process.spawn(*cmd))
      rescue SystemCallError => e
        msg_box("Open File", "Couldn't open #{path}:\n#{e.message}")
      end

      def misspelled_words(scr)
        return [] unless scr&.status&.connected?

        spelling&.misspelled(scr) || []
      end

      # Checks the current screen and keeps the answer for drawing. Called
      # from the timer pump and after spelling settings change - never while
      # painting: opening the Windows checker handles window messages, and a
      # repaint in the middle of a paint crashes the app.
      def refresh_spelling(redraw: true)
        scr = @controller.snapshot
        @misspelled = [scr, misspelled_words(scr)]
        self.redraw if redraw
      end

      def draw_misspellings(scr, cw, ch, ox, oy)
        shown, words = @misspelled
        return unless scr.same_content?(shown) # not checked yet: the pump will
        return unless @spelling # not `spelling`: that can open the checker and read files

        words.each do |word|
          @spelling.cells(word, scr.cols, scr.rows).group_by(&:first).each do |row, cells|
            cols = cells.map(&:last)
            squiggle(ox + (cols.min * cw), ox + ((cols.max + 1) * cw), oy + ((row + 1) * ch), ch)
          end
        end
      end

      # A zigzag along the bottom of a run of cells.
      def squiggle(x1, x2, bottom, ch)
        amp = [ch * 0.07, 1.5].max
        step = amp * 1.6
        y = bottom - amp - 1
        points = []
        x = x1
        i = 0
        while x <= x2
          points.push(x, i.even? ? y + amp : y - amp)
          x += step
          i += 1
        end
        @painter.polyline(points, SQUIGGLE, [ch * 0.05, 1.2].max) if points.size >= 4
      end

      # Right-click on a misspelled word (with no selection): its menu.
      def spell_click(event)
        cell = cell_at(event)
        word = cell && spelling&.word_at(@controller.snapshot, *cell)
        return false unless word

        UI.queue_main { spell_menu(word) }
        true
      end

      # Ctrl+;: the next misspelled word after the cursor (wrapping round)
      # gets the cursor and opens its menu below it.
      def spell_next
        scr = @controller.snapshot
        words = misspelled_words(scr)
        unless spelling
          @controller.flash(@config["spell_check"] ? "Spell check isn't available on this computer" : "Spell check is off (View menu)")
          return
        end
        return @controller.flash("No misspelled words") if words.empty?

        here = (scr.cursor_row * scr.cols) + scr.cursor_col
        word = words.find { |w| (w.row * scr.cols) + w.col > here } || words.first
        @controller.move_to(word.row, word.col)
        UI.queue_main { spell_menu(word, below: true) }
      end

      def spell_menu(word, below: false)
        suggestions = spelling.suggest(word.text).first(MAX_SUGGESTIONS)
        items = suggestions.empty? ? [["(no suggestions)", false]] : suggestions.dup
        items += [nil, "Ignore \"#{word.text}\"", "Add \"#{word.text}\" to the Windows dictionary"]
        choice = Win32.choose(@area.control, items, at: below ? word_screen_point(word) : nil)
        return unless choice

        if choice < suggestions.size
          @controller.replace_word(word.row, word.col, word.text, suggestions[choice])
        elsif choice == items.size - 2
          spell_ignore(word.text)
        elsif choice == items.size - 1
          dictionary_word = word.text.match?(/[[:lower:]]/) ? word.text : word.text.downcase
          spelling.checker.add(dictionary_word)
          spelling.forget
        end
        refresh_spelling
      end

      def spell_ignore(text)
        spelling.ignore(text)
        SpellWords.add(@config, [text])
        @words_stamp = SpellWords.stamp(@config) # our own change: no need to reload
      end

      # Screen point just under a word's first letter.
      def word_screen_point(word)
        w, h = @area_size
        return nil unless w

        _, cw, ch, ox, oy = metrics(w, h)
        Win32.client_to_screen(@area.control, ox + (word.col * cw), oy + ((word.row + 1) * ch) + 2)
      end

      def set_spell_check(on)
        set_option("spell_check", on)
        refresh_spelling
      end

      # View > Spell Check Language...: the languages Windows has, as a menu.
      def choose_spell_language
        langs = SpellChecker.languages
        if langs.empty?
          msg_box("Spell Check", "Windows has no spell checking languages installed.\n" \
                                 "Add one in Settings > Time & language > Language & region.")
          return
        end
        current = @config["spell_language"]
        default = "Windows display language (#{SpellChecker.user_language})"
        items = [(current ? "" : "✓ ") + default, nil] + langs.map { |l| (l == current ? "✓ " : "") + l }
        choice = Win32.choose(@area.control, items)
        return unless choice

        @config["spell_language"] = choice.zero? ? nil : langs[choice - 2]
        @config.save
        refresh_spelling
      end
    end
  end
end
