# frozen_string_literal: true

module Tn3270
  # One character position. `attr` is set when the cell holds a field
  # attribute (it then displays as a blank).
  # `input` is true for cells inside an unprotected field of a formatted screen.
  Cell = Struct.new(:char, :color, :bright, :hidden, :protected_field, :attr, :highlight, :input,
                    keyword_init: true)

  # A field on the screen. `row`/`col` are where its data starts (0-based),
  # one position after the attribute byte.
  Field = Struct.new(:row, :col, :length, :protected_field, :numeric, :hidden, :bright,
                     :modified, :color, :value, keyword_init: true) do
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
      @cells = Array.new(@rows * @cols) { Cell.new(char: " ") }
      @fields = []
    end

    def cell(row, col) = @cells[(row * @cols) + col]

    def row_text(row) = @cells[row * @cols, @cols].map(&:char).join

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

    def parse(lines)
      fattr = nil # current field attributes
      sattr = {}  # current character attributes (SA orders)
      field_starts = []
      pos = 0
      lines.each do |line|
        line.scan(/S[FA]\([^)]*\)|\S+/).each do |tok|
          if tok.start_with?("SF(")
            fattr = decode_pairs(tok)
            sattr = {}
            field_starts << [pos, fattr]
            @cells[pos] = Cell.new(char: " ", attr: fattr, protected_field: true)
            pos += 1
          elsif tok.start_with?("SA(")
            sattr = sattr.merge(decode_pairs(tok))
          else
            @cells[pos] = make_cell(tok, fattr, sattr) if pos < @cells.size
            pos += 1
          end
        end
      end
      build_fields(field_starts)
    end

    def decode_pairs(tok)
      tok[3..-2].split(",").to_h { |kv| k, v = kv.split("="); [k, v.to_i(16)] }
    end

    def make_cell(tok, fattr, sattr)
      code = tok.to_i(16)
      base = fattr ? fattr["c0"] : 0
      hidden = (base & 0x0C) == 0x0C
      char = if code.zero? || hidden then " "
             elsif tok.size > 2 then [tok].pack("H*").force_encoding("UTF-8") # multi-byte UTF-8
             else [code].pack("U")
             end
      color_code = sattr["42"] || fattr&.fetch("42", nil)
      Cell.new(
        char: char,
        color: COLOR_NAMES[color_code] || default_color(base, fattr.nil?),
        bright: (base & 0x0C) == 0x08,
        hidden: hidden,
        protected_field: fattr ? (base & 0x20) != 0 : false,
        input: fattr ? (base & 0x20).zero? : false,
        highlight: sattr["41"] || fattr&.fetch("41", nil)
      )
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
        value = (0...len).map { |k| @cells[(data_pos + k) % total].char }.join
        base = a["c0"]
        @fields << Field.new(
          row: data_pos / @cols, col: data_pos % @cols, length: len,
          protected_field: (base & 0x20) != 0, numeric: (base & 0x10) != 0,
          hidden: (base & 0x0C) == 0x0C, bright: (base & 0x0C) == 0x08,
          modified: (base & 0x01) != 0, color: COLOR_NAMES[a["42"]], value: value.rstrip
        )
      end
    end
  end
end
