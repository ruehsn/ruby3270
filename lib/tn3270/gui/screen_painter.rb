# frozen_string_literal: true

require_relative "font_metrics"

module Tn3270
  module Gui
    # Drawing shared by the main window and the history window. Include it in
    # a class that includes Glimmer, and call it from an area's on_draw.
    module ScreenPainter
      # 3270 color name -> RGB
      PALETTE = {
        neutral: [0xE0, 0xE0, 0xE0], blue: [0x6C, 0x9B, 0xFF], red: [0xFF, 0x55, 0x55],
        pink: [0xFF, 0x79, 0xE6], green: [0x4C, 0xE0, 0x6A], turquoise: [0x3F, 0xE0, 0xE0],
        yellow: [0xFF, 0xE0, 0x4C], white: [0xF4, 0xF4, 0xF4], black: [0x00, 0x00, 0x00],
        deep_blue: [0x5A, 0x6C, 0xF0], orange: [0xFF, 0xA5, 0x33], purple: [0xB3, 0x7D, 0xFF],
        pale_green: [0xA8, 0xF0, 0xA8], pale_turquoise: [0xAF, 0xEE, 0xEE], grey: [0xA0, 0xA0, 0xA0]
      }.freeze
      BACKGROUND = [0x0B, 0x0E, 0x12].freeze

      def rgb(arr, alpha = 1.0) = { r: arr[0], g: arr[1], b: arr[2], a: alpha }

      # Largest font size that fits rows x cols (plus `extra_rows`) into the
      # box, and the grid placed in its center:
      #   [font_size, cell_width, cell_height, left, top]
      def fit_grid(rows, cols, x, y, width, height, font, extra_rows: 0, top: false)
        fm = FontMetrics.for(font)
        size = [width / (cols * fm[:advance]), height / ((rows + extra_rows) * fm[:line])].min
        size = [size, 1.0].max
        cw = size * fm[:advance]
        ch = size * fm[:line]
        left = x + [(width - (cw * cols)) / 2.0, 0].max
        spare = [height - (ch * (rows + extra_rows)), 0].max
        [size, cw, ch, left, y + (top ? 0 : spare / 2.0)]
      end

      # Draws every character of a screen. Each row is drawn as runs of
      # same-styled text, each run placed at its own column so it can't drift.
      def paint_cells(scr, size, cw, ch, ox, oy, font, underline: true)
        scr.rows.times do |r|
          y = oy + (r * ch)
          style_runs(scr, r).each do |col, str, cell|
            x = ox + (col * cw)
            fg = PALETTE[cell.color] || PALETTE[:green]
            if cell.highlight == 0xF2 # reverse video
              rectangle(x, y, str.size * cw, ch) { fill rgb(fg) }
              fg = BACKGROUND
            end
            if (underline && cell.input) || cell.highlight == 0xF4
              rectangle(x, y + ch - [ch * 0.08, 1].max, str.size * cw, [ch * 0.06, 1].max) { fill rgb(fg, 0.55) }
            end
            next if str.strip.empty?

            text(x, y, (str.size + 4) * cw) {
              default_font family: font, size: size, weight: cell.bright ? :bold : :normal
              string(str) { color rgb(fg) }
            }
          end
        end
      end

      # A miniature of a screen: each word becomes a small colored bar.
      # Much cheaper than text and still recognisable at thumbnail size.
      def paint_minimap(scr, x, y, width, height)
        cw = width / scr.cols.to_f
        ch = height / scr.rows.to_f
        bar_h = [ch * 0.7, 1].max
        minimap_runs(scr).each do |row, c1, c2, color|
          rectangle(x + (c1 * cw), y + (row * ch), (c2 - c1 + 1) * cw, bar_h) { fill rgb(PALETTE[color] || PALETTE[:green], 0.9) }
        end
      end

      # [[row, first_col, last_col, color], ...] for each word on the screen.
      def minimap_runs(scr)
        runs = []
        scr.rows.times do |r|
          start = nil
          color = nil
          (0..scr.cols).each do |c|
            cell = c < scr.cols ? scr.cell(r, c) : nil
            blank = cell.nil? || cell.char.strip.empty?
            if start && (blank || cell.color != color)
              runs << [r, start, c - 1, color]
              start = nil
            end
            if !blank && start.nil?
              start = c
              color = cell.color
            end
          end
        end
        runs
      end

      # [[start_col, text, style_cell], ...] for one row.
      def style_runs(scr, row)
        runs = []
        scr.cols.times do |c|
          cell = scr.cell(row, c)
          key = [cell.color, cell.bright, cell.highlight, cell.input, !cell.attr.nil?]
          if runs.last && runs.last[3] == key
            runs.last[1] << cell.char
          else
            runs << [c, cell.char.dup, cell, key]
          end
        end
        runs.map { |c, s, cell, _| [c, s, cell] }
      end
    end
  end
end
