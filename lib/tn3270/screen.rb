# frozen_string_literal: true

module Tn3270
  # One character position. `attr` is set when the cell holds a field
  # attribute (it then displays as a blank).
  # `input` is true for cells inside an unprotected field of a formatted screen.
  # Cells are frozen, and positions that look the same share one Cell.
  Cell = Struct.new(:char, :color, :bright, :hidden, :protected_field, :attr, :highlight, :input)

  # A field on the screen. `row`/`col` are where its data starts (0-based),
  # one position after the attribute byte.
  Field = Struct.new(:row, :col, :length, :protected_field, :numeric, :hidden, :bright,
                     :modified, :color, :value) do
    def input? = !protected_field
    def to_s = value
  end

  # A snapshot of the screen built from ReadBuffer(Ascii).
  class Screen
    # 3270 color code -> name
    COLOR_NAMES = {
      0xF0 => :neutral, 0xF1 => :blue, 0xF2 => :red, 0xF3 => :pink, 0xF4 => :green,
      0xF5 => :turquoise, 0xF6 => :yellow, 0xF7 => :white, 0xF8 => :black, 0xF9 => :deep_blue,
      0xFA => :orange, 0xFB => :purple, 0xFC => :pale_green, 0xFD => :pale_turquoise,
      0xFE => :grey, 0xFF => :white
    }.freeze
    BLANK = Cell.new(" ").freeze

    attr_reader :rows, :cols, :cells, :fields, :cursor_row, :cursor_col, :status

    def self.from_buffer(lines, status)
      new(status).tap { |s| s.send(:parse, lines) }
    end

    def initialize(status)
      @status = status
      @rows = status&.rows.to_i.positive? ? status.rows : 24
      @cols = status&.cols.to_i.positive? ? status.cols : 80
      @cursor_row = status&.cursor_row.to_i
      @cursor_col = status&.cursor_col.to_i
      @cells = Array.new(@rows * @cols, BLANK)
      @fields = []
      @row_texts = []
      @memo = {}
    end

    # Something worked out from the screen's contents, kept with the screen
    # so it's only worked out once:
    #   screen.memo(:word_count) { screen.text.split.size }
    # Copies made by with_status share it (their contents are the same).
    def memo(key) = @memo.fetch(key) { @memo[key] = yield }

    # The same screen under a newer status line: the cursor moved, or a
    # status flag changed, but no character did. The copy shares this
    # screen's cells and fields, so it costs next to nothing to make.
    # Returns nil if the screen size differs (parse the buffer instead).
    def with_status(status)
      copy = dup
      copy.send(:status=, status)
      copy if copy.rows == @rows && copy.cols == @cols
    end

    # True if `other` holds the very same characters and fields as this
    # screen (it was made from it by with_status). Only the cursor and the
    # status flags can differ.
    def same_content?(other) = !other.nil? && @cells.equal?(other.cells)

    def cell(row, col) = @cells[(row * @cols) + col]

    def row_text(row) = @row_texts[row] ||= @cells[row * @cols, @cols].map(&:char).join.freeze

    # Screen text with hidden fields blanked out.
    def text = (0...@rows).map { |r| row_text(r) }.join("\n")

    # Text in a rectangle of the screen (corners in any order), one line per
    # row with trailing blanks removed.
    def region_text(row1, col1, row2, col2)
      r1, r2 = [row1, row2].minmax
      c1, c2 = [col1, col2].minmax
      (r1..r2).map { |r| row_text(r)[c1..c2].rstrip }.join("\n")
    end

    def include?(needle) = text.include?(needle)

    # Every place `term` appears, row by row: [[row, col, length], ...].
    # Matches don't run across the end of a row.
    def find(term, match_case: false)
      return [] if term.to_s.empty?

      needle = match_case ? term : term.downcase
      (0...@rows).flat_map do |r|
        line = match_case ? row_text(r) : row_text(r).downcase
        hits = []
        start = 0
        while (i = line.index(needle, start))
          hits << [r, i, needle.size]
          start = i + 1
        end
        hits
      end
    end

    def input_fields = @fields.select(&:input?)

    def field_at(row, col)
      pos = (row * @cols) + col
      @fields.find do |f|
        start = (f.row * @cols) + f.col
        pos >= start && pos < start + [f.length, 1].max
      end
    end

    # Text immediately left of a field, handy for finding fields by label:
    #   screen.field_after("USER ID")
    def field_after(label)
      input_fields.find do |f|
        before = row_text(f.row)[0...f.col]
        before.rstrip.end_with?(label) || before.include?(label)
      end
    end

    private

    def status=(status)
      @status = status
      @rows = status&.rows.to_i.positive? ? status.rows : 24
      @cols = status&.cols.to_i.positive? ? status.cols : 80
      @cursor_row = status&.cursor_row.to_i
      @cursor_col = status&.cursor_col.to_i
    end

    # A buffer line is hex character codes separated by spaces, with
    # SF(...) where a field starts and SA(...) where character attributes
    # change: "SF(c0=e0) 41 42 SA(42=f2) 43".
    def parse(lines)
      fattr = nil # current field attributes
      sattr = {}  # current character attributes (SA orders)
      made = {}   # code => Cell under the current attributes (shared by equal positions)
      field_starts = []
      pos = 0
      size = @cells.size
      lines.each do |line|
        line.split.each do |tok|
          if tok.start_with?("SF(")
            fattr = decode_pairs(tok)
            sattr = {}
            made = {}
            if pos < size # (a buffer longer than the screen is cut off)
              field_starts << [pos, fattr]
              @cells[pos] = Cell.new(" ", nil, nil, nil, true, fattr).freeze
            end
            pos += 1
          elsif tok.start_with?("SA(")
            sattr = sattr.merge(decode_pairs(tok))
            made = {}
          else
            @cells[pos] = (made[tok] ||= make_cell(tok, fattr, sattr)) if pos < size
            pos += 1
          end
        end
      end
      first = field_starts.first
      wrap_last_field(lines, first[0], field_starts.last[1]) if first && first[0].positive?
      build_fields(field_starts)
    end

    # The last field runs past the end of the screen and on from the top, so
    # the cells before the first field are part of it: they take its color
    # and protection.
    def wrap_last_field(lines, upto, fattr)
      sattr = {}
      pos = 0
      lines.each do |line|
        line.split.each do |tok|
          return if pos >= upto

          if tok.start_with?("SA(")
            sattr = sattr.merge(decode_pairs(tok))
          else
            @cells[pos] = make_cell(tok, fattr, sattr)
            pos += 1
          end
        end
      end
    end

    def decode_pairs(tok)
      tok[3..-2].split(",").to_h { |kv| k, v = kv.split("="); [k, v.to_i(16)] }
    end

    def make_cell(tok, fattr, sattr)
      code = tok.to_i(16)
      base = fattr ? fattr["c0"] : 0
      hidden = (base & 0x0C) == 0x0C
      char = if code.zero? || hidden then " "
             elsif tok.size > 2 then [tok].pack("H*").force_encoding("UTF-8").freeze # multi-byte UTF-8
             else [code].pack("U").freeze
             end
      color_code = sattr["42"] || fattr&.fetch("42", nil)
      Cell.new(
        char,
        COLOR_NAMES[color_code] || default_color(base, fattr.nil?),
        (base & 0x0C) == 0x08,                       # bright
        hidden,
        fattr ? (base & 0x20) != 0 : false,          # protected_field
        nil,                                         # attr
        sattr["41"] || fattr&.fetch("41", nil),      # highlight
        fattr ? (base & 0x20).zero? : false          # input
      ).freeze
    end

    # Base-color 3270 defaults: protected/unprotected x normal/intensified.
    def default_color(base, unformatted)
      return :green if unformatted

      prot = (base & 0x20) != 0
      bright = (base & 0x0C) == 0x08
      if prot then bright ? :white : :blue
      else bright ? :red : :green
      end
    end

    def build_fields(starts)
      return if starts.empty?

      total = @rows * @cols
      starts.each_with_index do |(pos, a), i|
        nxt = starts[(i + 1) % starts.size][0]
        len = (nxt - pos - 1) % total
        len = total - 1 if starts.size == 1
        data_pos = (pos + 1) % total
        base = a["c0"]
        @fields << Field.new(
          row: data_pos / @cols, col: data_pos % @cols, length: len,
          protected_field: (base & 0x20) != 0, numeric: (base & 0x10) != 0,
          hidden: (base & 0x0C) == 0x0C, bright: (base & 0x0C) == 0x08,
          modified: (base & 0x01) != 0, color: COLOR_NAMES[a["42"]], value: chars(data_pos, len).rstrip
        )
      end
    end

    # `len` characters starting at buffer position `pos`, wrapping from the
    # end of the screen to the top.
    def chars(pos, len)
      cells = @cells[pos, len]
      cells.concat(@cells[0, len - cells.size]) if cells.size < len
      cells.map(&:char).join
    end
  end
end
