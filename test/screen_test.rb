# frozen_string_literal: true

# Screen parsing and the drawing plan, from hand-written buffers (no host and
# no window):  ruby -Ilib test/screen_test.rb
require "minitest/autorun"
require "tn3270"
require "tn3270/gui/screen_painter"
require "tn3270/gui/font_metrics"

class ScreenTest < Minitest::Test
  # A 2x10 screen:
  #   row 0: X Y [protected] I D [input] a b _ _
  #   row 1: _ _ [protected, bright, red] O K (reverse)! _ _ (underscored)Z Z
  # The red field runs off the end of the screen and on to "XY" at the top.
  BUFFER = ["58 59 SF(c0=e0) 49 44 SF(c0=c0) 61 62 20 20",
            "20 20 SF(c0=e8,42=f2) 4f 4b SA(41=f2) 21 SA(41=00) 20 20 SA(41=f4) 5a 5a"].freeze

  def status(cursor_row = 0, cursor_col = 0, rows: 2, cols: 10)
    Tn3270::Status.parse("U F U C(h) I 2 #{rows} #{cols} #{cursor_row} #{cursor_col} 0x0 -")
  end

  def screen(lines = BUFFER, **opts) = Tn3270::Screen.from_buffer(lines, status(**opts))

  def test_cells_take_their_fields_attributes
    scr = screen
    assert_equal ["XY ID ab  ", "   OK!  ZZ"], [scr.row_text(0), scr.row_text(1)]
    id = scr.cell(0, 3)
    assert_equal [:blue, false, true, false], [id.color, id.bright, id.protected_field, id.input]
    typed = scr.cell(0, 6)
    assert_equal [:green, false, true], [typed.color, typed.protected_field, typed.input]
    assert scr.cell(1, 1).input, "the input field runs on to the next row"
    ok = scr.cell(1, 3)
    assert_equal [:red, true, true], [ok.color, ok.bright, ok.protected_field]
    assert_equal 0xF2, scr.cell(1, 5).highlight
    assert_equal 0xF4, scr.cell(1, 8).highlight
    assert scr.cell(0, 2).attr, "a field attribute takes up a cell"
  end

  def test_fields_and_a_field_that_wraps_to_the_top
    scr = screen
    assert_equal ["ID", "ab", "OK!  ZZXY"], scr.fields.map(&:value)
    assert_equal [[0, 3, 2], [0, 6, 6], [1, 3, 9]], scr.fields.map { |f| [f.row, f.col, f.length] }
    assert_equal ["ab"], scr.input_fields.map(&:value)
    assert_equal "ab", scr.field_at(1, 1).value
    # The cells before the first field are part of the last one.
    top = scr.cell(0, 0)
    assert_equal [:red, true, true, false], [top.color, top.bright, top.protected_field, top.input]
  end

  def test_keyword_and_positional_structs
    cell = Tn3270::Cell.new(char: "A", color: :red)
    assert_equal ["A", :red, nil], [cell.char, cell.color, cell.bright]
    field = Tn3270::Field.new(row: 1, col: 2, length: 3, value: "abc")
    assert field.input?
    assert_equal "abc", field.to_s
  end

  def test_an_unformatted_screen_has_no_fields
    scr = screen(["48 49 00 00 00 00 00 00 00 00", "00 00 00 00 00 00 00 00 00 00"])
    assert_empty scr.fields
    assert_equal "HI", scr.row_text(0).rstrip
    assert_equal [:green, false, false], [scr.cell(0, 0).color, scr.cell(0, 0).protected_field, scr.cell(0, 0).input]
  end

  def test_one_field_covers_the_rest_of_the_screen
    scr = screen(["41 SF(c0=c0) 42 43 20 20 20 20 20 20", "20 20 20 20 20 20 20 20 20 5a"])
    assert_equal 1, scr.fields.size
    assert_equal 19, scr.fields.first.length
    assert_equal "BC               ZA", scr.fields.first.value
    assert scr.cell(0, 0).input
  end

  def test_a_short_or_long_buffer_is_harmless
    assert_equal "AB        ", screen(["41 42"]).row_text(0)
    long = screen([(["41"] * 10).join(" "), (["42"] * 10).join(" "), "43 SF(c0=c0) 44"])
    assert_equal 20, long.cells.size
    assert_equal "BBBBBBBBBB", long.row_text(1)
  end

  def test_multi_byte_and_hidden_characters
    scr = screen(["SF(c0=c0) c3a9 41 SF(c0=cc) 53 45 43 20 20 20", "20 20 20 20 20 20 20 20 20 20"])
    assert_equal "é", scr.cell(0, 1).char
    assert_equal " éA       ", scr.row_text(0), "a hidden field reads as blanks"
    assert scr.fields[1].hidden
    assert_equal "", scr.fields[1].value
  end

  def test_equal_positions_share_one_frozen_cell
    scr = screen
    assert_same scr.cell(0, 8), scr.cell(0, 9)
    assert_same scr.cell(0, 8), scr.cell(1, 0)
    assert scr.cell(0, 6).frozen?
    assert_raises(FrozenError) { scr.cell(0, 6).char << "x" }
    refute_same scr.cell(0, 6), scr.cell(0, 7)
  end

  def test_with_status_moves_the_cursor_without_copying_the_screen
    scr = screen
    moved = scr.with_status(status(1, 4))
    assert_equal [1, 4], [moved.cursor_row, moved.cursor_col]
    assert_equal [0, 0], [scr.cursor_row, scr.cursor_col], "the original is untouched"
    assert_same scr.cells, moved.cells
    assert_same scr.fields, moved.fields
    assert moved.same_content?(scr)
    assert scr.same_content?(moved)
    assert_equal scr.text, moved.text
  end

  def test_same_content_is_false_for_another_parse_or_nothing
    scr = screen
    refute scr.same_content?(screen)
    refute scr.same_content?(nil)
  end

  def test_with_status_refuses_another_screen_size
    assert_nil screen.with_status(status(rows: 3, cols: 10))
  end

  def test_memo_is_worked_out_once_and_shared_with_copies
    scr = screen
    calls = 0
    2.times { assert_equal 20, scr.memo(:size) { calls += 1; scr.cells.size } }
    assert_equal 20, scr.with_status(status(1, 1)).memo(:size) { calls += 1 }
    assert_equal 1, calls
    assert_nil(scr.memo(:nothing) { nil })
    assert_nil(scr.memo(:nothing) { flunk "a nil answer is remembered too" })
  end

  def test_row_text_is_remembered
    scr = screen
    assert_same scr.row_text(1), scr.row_text(1)
    assert_equal "ID", scr.region_text(0, 3, 0, 4)
  end
end

class PaintPlanTest < Minitest::Test
  P = Tn3270::Gui::ScreenPainter

  def setup
    @painter = Object.new.extend(P)
    status = Tn3270::Status.parse("U F U C(h) I 2 2 10 0 0 0x0 -")
    @scr = Tn3270::Screen.from_buffer(ScreenTest::BUFFER, status)
    @status2 = Tn3270::Status.parse("U F U C(h) I 2 2 10 1 5 0x0 -")
  end

  def test_runs_split_where_the_style_changes
    runs = @painter.style_runs(@scr, 1).map { |col, str, _cell| [col, str] }
    assert_equal [[0, "  "], [2, " "], [3, "OK"], [5, "!"], [6, "  "], [8, "ZZ"]], runs
  end

  def test_plan_groups_backgrounds_underlines_and_text
    plan = @painter.paint_plan(@scr)
    red = P::PALETTE[:red]
    green = P::PALETTE[:green]
    assert_equal({ red => [[1, 5, 1]] }, plan.blocks)
    assert_equal({ red => [[1, 8, 2]] }, plan.underlines)
    assert_equal({ green => [[0, 6, 4], [1, 0, 2]] }, plan.input_lines)
    assert_equal [[0, 0, "XY", red, true], [0, 3, "ID", P::PALETTE[:blue], false], [0, 6, "ab  ", green, false],
                  [1, 3, "OK", red, true], [1, 5, "!", P::BACKGROUND, true], [1, 8, "ZZ", red, true]], plan.texts
  end

  def test_plan_is_reused_after_a_cursor_move
    plan = @painter.paint_plan(@scr)
    assert_same plan, @painter.paint_plan(@scr)
    assert_same plan, @painter.paint_plan(@scr.with_status(@status2))
  end

  # Records what paint_cells asks the painter to draw.
  class FakePainter
    attr_reader :rects, :texts

    def initialize
      @rects = []
      @texts = []
    end

    def fill_rects(rects, rgb, alpha = 1.0) = @rects << [rects, rgb, alpha]
    def text(x, y, _width, str, rgb, _font, _size, bold: false) = @texts << [x, y, str, rgb, bold]
  end

  def test_paint_cells_places_everything_on_the_grid
    pt = FakePainter.new
    @painter.paint_cells(pt, @scr, 12, 10.0, 20.0, 100.0, 50.0, "Consolas")
    red = P::PALETTE[:red]
    assert_equal [[[100.0 + 50, 50.0 + 20, 10.0, 20.0]], red, 1.0], pt.rects[0], "reverse video block"
    assert_equal [[[180.0, 70.0 + 20 - 1.6, 20.0, 1.2]], red, 0.55], pt.rects[1], "underscore"
    assert_equal 2, pt.rects[2][0].size, "input field lines"
    assert_equal [100.0, 50.0, "XY", red, true], pt.texts.first
    assert_equal 6, pt.texts.size
  end

  def test_input_lines_can_be_switched_off
    pt = FakePainter.new
    @painter.paint_cells(pt, @scr, 12, 10.0, 20.0, 0.0, 0.0, "Consolas", underline: false)
    assert_equal 2, pt.rects.size, "the block and the underscore, but no input lines"
  end

  def test_minimap_runs_are_one_bar_per_word
    runs = @painter.minimap_runs(@scr)
    assert_equal [[0, 0, 1, :red], [0, 3, 4, :blue], [0, 6, 7, :green], [1, 3, 5, :red], [1, 8, 9, :red]], runs
    assert_same runs, @painter.minimap_runs(@scr)
  end
end

# Text widths are remembered, but not without limit (tab titles and
# tooltips keep changing). Measuring itself needs a window, so it's faked.
class FontMetricsTest < Minitest::Test
  FM = Tn3270::Gui::FontMetrics

  def setup
    @measured = measured = []
    @extents = FM.method(:extents)
    FM.define_singleton_method(:extents) do |_family, text, **|
      measured << text
      [text.size * 7.0, 12.0]
    end
    FM.instance_variable_set(:@widths, nil)
  end

  def teardown
    FM.define_singleton_method(:extents, @extents)
    FM.instance_variable_set(:@widths, nil)
  end

  def test_a_width_is_measured_once
    2.times { assert_equal 21.0, FM.text_width("Segoe UI", 9, "abc") }
    assert_equal 21.0, FM.text_width("Segoe UI", 9, "abc", bold: true)
    assert_equal %w[abc abc], @measured, "once plain, once bold"
  end

  def test_remembered_widths_are_capped
    (FM::MAX_WIDTHS + 50).times { |i| FM.text_width("Segoe UI", 9, "title #{i}") }
    assert_operator FM.instance_variable_get(:@widths).size, :<=, FM::MAX_WIDTHS
    count = @measured.size
    FM.text_width("Segoe UI", 9, "title #{FM::MAX_WIDTHS + 49}")
    assert_equal count, @measured.size, "a recent one is still remembered"
  end
end
