# frozen_string_literal: true

require "minitest/autorun"
require "tn3270"
require "tn3270/gui/spelling"
require "tn3270/gui/spell_checker"
require "tn3270/gui/keymap"

class SpellingTest < Minitest::Test
  Spelling = Tn3270::Gui::Spelling
  FakeScreen = Struct.new(:fields, :rows, :cols)

  # Knows a few words, the way Windows does: case matters for names.
  class FakeChecker
    WORDS = %w[the job ran please check output tomorrow London receive it's].freeze
    attr_reader :asked

    def initialize = @asked = []

    def correct?(word)
      @asked << word
      WORDS.include?(word) || WORDS.include?(word.downcase) && word != "london"
    end

    def suggest(word) = { "teh" => %w[the ten], "recieve" => ["receive"] }.fetch(word.downcase, [])
  end

  def field(value, row: 2, col: 10, length: 40, protected: false, hidden: false)
    Tn3270::Field.new(row: row, col: col, length: length, protected_field: protected, hidden: hidden, value: value)
  end

  def screen(*fields) = FakeScreen.new(fields, 24, 80)

  def setup
    @checker = FakeChecker.new
    @sp = Spelling.new(@checker, min_field: 20)
  end

  def flagged(*fields) = @sp.misspelled(screen(*fields)).map(&:text)

  def test_finds_misspelled_words_with_their_position
    words = @sp.misspelled(screen(field("teh job ran, plese check")))
    assert_equal %w[teh plese], words.map(&:text)
    assert_equal [[2, 10], [2, 23]], words.map { |w| [w.row, w.col] }
  end

  def test_a_new_shortest_field_length_checks_the_same_screen_again
    scr = screen(field("teh", length: 8))
    assert_empty @sp.misspelled(scr)
    @sp.min_field = 5
    assert_equal ["teh"], @sp.misspelled(scr).map(&:text)
    asked = @checker.asked.size
    @sp.min_field = 5 # unchanged: the remembered answer still stands
    assert_same @sp.misspelled(scr), @sp.misspelled(scr)
    assert_equal asked, @checker.asked.size
  end

  def test_skips_short_protected_and_hidden_fields
    assert_empty flagged(field("teh", length: 8))
    assert_empty flagged(field("teh plese", protected: true))
    assert_empty flagged(field("teh plese", hidden: true))
  end

  def test_leaves_codes_alone
    assert_empty flagged(field("SYS1.PROCLIB IEF142I &SYSUID a.b x1 ok to"))
  end

  def test_punctuation_around_words
    assert_equal ["plese"], flagged(field("(plese) \"the\" it's job."))
  end

  def test_all_caps_words_are_checked
    assert_equal %w[TEH JCL], flagged(field("TEH JOB RAN JCL"))
    assert_equal %w[JCL], flagged(field("Please check JCL output"))
    assert_empty flagged(field("PLEASE CHECK LONDON")) # LONDON passes as London
  end

  def test_suggestions_keep_the_words_case
    assert_equal %w[THE TEN], @sp.suggest("TEH")
    assert_equal %w[The Ten], @sp.suggest("Teh")
    assert_equal ["receive"], @sp.suggest("recieve")
  end

  def test_ignore_list
    sp = Spelling.new(@checker, ignored: ["Plese"])
    assert_equal ["teh"], sp.misspelled(screen(field("teh plese"))).map(&:text)
    sp.ignore("TEH")
    assert_empty sp.misspelled(screen(field("teh plese")))
  end

  def test_word_at_and_wrapping_cells
    scr = screen(field("ok the plese", row: 0, col: 75))
    word = @sp.word_at(scr, 1, 0) # "plese" starts at 0,82 -> row 1, col 2... so not this cell
    assert_nil word
    word = @sp.word_at(scr, 1, 4)
    assert_equal "plese", word.text
    assert_equal [[1, 2], [1, 3], [1, 4], [1, 5], [1, 6]], @sp.cells(word, 80, 24)
    wrap = Spelling::Word.new(row: 0, col: 78, text: "teh")
    assert_equal [[0, 78], [0, 79], [1, 0]], @sp.cells(wrap, 80, 24)
  end

  def test_remembers_answers
    scr = screen(field("teh teh teh job"))
    @sp.misspelled(scr)
    @sp.misspelled(screen(field("teh job")))
    assert_equal 1, @checker.asked.count("teh")
  end

  def test_ctrl_semicolon_is_next_misspelling
    event = { key: ";", key_value: 59, ext_key: nil, modifier: nil, modifiers: [:ctrl], up: false }
    assert_equal [:spell_next], Tn3270::Gui::Keymap.translate(event)
  end

  # The real Windows checker (read-only: never adds to your dictionary).
  def test_windows_checker
    checker = Tn3270::Gui::SpellChecker.open("en-US")
    skip "no Windows spell checker here" unless checker
    assert checker.correct?("receive")
    refute checker.correct?("recieve")
    assert_includes checker.suggest("recieve"), "receive"
    sp = Spelling.new(checker)
    assert_equal %w[RECIEVE], sp.misspelled(screen(field("PLEASE RECIEVE THE OUTPUT"))).map(&:text)
  end
end
