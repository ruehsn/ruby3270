# frozen_string_literal: true

require_relative "ui"
require_relative "font_metrics"
require_relative "theme"

module Tn3270
  module Gui
    # Draws on a libui drawing context. One Painter is reused for every
    # frame: its brush, stroke and font structs are allocated once.
    #   painter.context = params[:context]  (inside an Area's draw handler)
    #
    # Laid-out text is kept from one frame to the next: most frames draw the
    # same text as the one before (the cursor moved, the pointer is over a
    # button), and laying text out is the slow part of drawing it. Text a
    # frame didn't draw is freed when the next frame starts.
    class Painter
      ALIGN = { left: UI::DrawTextAlignLeft, center: UI::DrawTextAlignCenter, right: UI::DrawTextAlignRight }.freeze
      CAPS = { flat: UI::DrawLineCapFlat, round: UI::DrawLineCapRound }.freeze

      attr_reader :context

      # Starts a frame.
      def context=(context)
        @context = context
        @stale.each_value { |layout, string| free_layout(layout, string) }
        @stale = @layouts
        @layouts = {}
      end

      def initialize
        @layouts = {} # [text, color, font...] => [layout, its string], drawn this frame
        @stale = {}   # ...drawn last frame and not yet this one
        @brush = UI::FFI::DrawBrush.malloc
        @brush.Type = UI::DrawBrushTypeSolid
        @stroke = UI::FFI::DrawStrokeParams.malloc
        @stroke.MiterLimit = UI::DrawDefaultMiterLimit
        @stroke.Dashes = nil
        @stroke.NumDashes = 0
        @stroke.DashPhase = 0
        @layout = UI::FFI::DrawTextLayoutParams.malloc
        @fonts = {}
        @names = {}
      end

      # rgb: [r, g, b] 0-255; alpha 0.0-1.0
      def fill_rect(x, y, w, h, rgb, alpha = 1.0)
        fill(alpha, rgb) { |p| UI.draw_path_add_rectangle(p, x, y, w, h) }
      end

      # Many rectangles ([x, y, w, h] each) in one color, drawn in one go.
      def fill_rects(rects, rgb, alpha = 1.0)
        return if rects.empty?

        fill(alpha, rgb) { |p| rects.each { |x, y, w, h| UI.draw_path_add_rectangle(p, x, y, w, h) } }
      end

      def stroke_rect(x, y, w, h, rgb, thickness = 1.0, alpha = 1.0)
        stroke(rgb, alpha, thickness) { |p| UI.draw_path_add_rectangle(p, x, y, w, h) }
      end

      def fill_circle(cx, cy, r, rgb, alpha = 1.0)
        fill(alpha, rgb) { |p| UI.draw_path_new_figure_with_arc(p, cx, cy, r, 0, 2 * Math::PI, 0) }
      end

      def stroke_circle(cx, cy, r, rgb, thickness = 1.0, alpha = 1.0)
        stroke(rgb, alpha, thickness) { |p| UI.draw_path_new_figure_with_arc(p, cx, cy, r, 0, 2 * Math::PI, 0) }
      end

      # points: [x1, y1, x2, y2, ...]
      def polyline(points, rgb, thickness = 1.0, alpha = 1.0, cap: :flat)
        stroke(rgb, alpha, thickness, cap: cap) do |p|
          UI.draw_path_new_figure(p, points[0], points[1])
          points.drop(2).each_slice(2) { |x, y| UI.draw_path_line_to(p, x, y) }
        end
      end

      # Text with its top-left corner at x, y; width wraps it (-1: no wrapping).
      def text(x, y, width, str, rgb, family, size, bold: false, align: :left, alpha: 1.0)
        return if str.nil? || str.empty?

        key = [str, rgb, family, size, bold, width, align, alpha]
        entry = @layouts[key] ||= @stale.delete(key) || new_layout(str, rgb, family, size, bold, width, align, alpha)
        UI.draw_text(@context, entry[0], x, y)
      end

      private

      # [layout, attributed string]: the string is kept for as long as the layout.
      def new_layout(str, rgb, family, size, bold, width, align, alpha)
        s = UI.new_attributed_string(str)
        attr = UI.new_color_attribute(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0, alpha)
        UI.attributed_string_set_attribute(s, attr, 0, str.bytesize) # the string owns the attribute now
        @layout.String = s
        @layout.DefaultFont = font(family, size, bold)
        @layout.Width = width
        @layout.Align = ALIGN.fetch(align)
        [UI.draw_new_text_layout(@layout), s]
      end

      def free_layout(layout, string)
        UI.draw_free_text_layout(layout)
        UI.free_attributed_string(string)
      end

      def set_brush(rgb, alpha)
        @brush.R = rgb[0] / 255.0
        @brush.G = rgb[1] / 255.0
        @brush.B = rgb[2] / 255.0
        @brush.A = alpha
        @brush
      end

      def path
        p = UI.draw_new_path(UI::DrawFillModeWinding)
        yield p
        UI.draw_path_end(p)
        p
      end

      def fill(alpha, rgb, &block)
        p = path(&block)
        UI.draw_fill(@context, p, set_brush(rgb, alpha))
        UI.draw_free_path(p)
      end

      def stroke(rgb, alpha, thickness, cap: :flat, &block)
        p = path(&block)
        @stroke.Thickness = thickness
        @stroke.Cap = CAPS.fetch(cap)
        @stroke.Join = cap == :round ? UI::DrawLineJoinRound : UI::DrawLineJoinMiter
        UI.draw_stroke(@context, p, set_brush(rgb, alpha), @stroke)
        UI.draw_free_path(p)
      end

      def font(family, size, bold)
        @fonts[[family, size, bold]] ||= begin
          f = UI::FFI::FontDescriptor.malloc
          @names[family] ||= Fiddle::Pointer["#{family}\0"] # kept alive with the descriptor
          f.Family = @names[family]
          f.Size = size
          f.Weight = bold ? UI::TextWeightBold : UI::TextWeightNormal
          f.Italic = UI::TextItalicNormal
          f.Stretch = UI::TextStretchNormal
          f
        end
      end
    end

    # Drawing shared by the main window and the history window.
    module ScreenPainter
      include Theme

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

      # What paint_cells draws for a screen, in rows and columns. Spans are
      # [row, col, length], grouped by color ({ rgb => [span, ...] }):
      #   blocks      reverse-video backgrounds
      #   underlines  lines under underscored text
      #   input_lines lines under input fields (drawn if that setting is on)
      #   texts       [[row, col, string, rgb, bold], ...]
      PaintPlan = Struct.new(:blocks, :underlines, :input_lines, :texts)

      # Draws every character of a screen. Each row is drawn as runs of
      # same-styled text, each run placed at its own column so it can't drift.
      # Backgrounds and underlines of one color are drawn together.
      def paint_cells(pt, scr, size, cw, ch, ox, oy, font, underline: true)
        plan = paint_plan(scr)
        plan.blocks.each do |rgb, spans|
          pt.fill_rects(spans.map { |r, c, n| [ox + (c * cw), oy + (r * ch), n * cw, ch] }, rgb)
        end
        line_y = oy + ch - [ch * 0.08, 1].max
        line_h = [ch * 0.06, 1].max
        (underline ? [plan.underlines, plan.input_lines] : [plan.underlines]).each do |lines|
          lines.each do |rgb, spans|
            pt.fill_rects(spans.map { |r, c, n| [ox + (c * cw), line_y + (r * ch), n * cw, line_h] }, rgb, 0.55)
          end
        end
        plan.texts.each do |r, c, str, rgb, bold|
          pt.text(ox + (c * cw), oy + (r * ch), (str.size + 4) * cw, str, rgb, font, size, bold: bold)
        end
      end

      # The PaintPlan for a screen. It's kept with the screen, so it is worked
      # out once however many frames show that screen (a cursor move doesn't
      # change it).
      def paint_plan(scr)
        scr.memo(:paint_plan) do
          plan = PaintPlan.new({}, {}, {}, [])
          scr.rows.times do |r|
            style_runs(scr, r).each do |col, str, cell|
              fg = PALETTE[cell.color] || PALETTE[:green]
              span = [r, col, str.size]
              if cell.highlight == 0xF2 # reverse video
                (plan.blocks[fg] ||= []) << span
                fg = BACKGROUND
              end
              if cell.highlight == 0xF4 then (plan.underlines[fg] ||= []) << span
              elsif cell.input then (plan.input_lines[fg] ||= []) << span
              end
              plan.texts << [r, col, str, fg, cell.bright] unless str.strip.empty?
            end
          end
          plan
        end
      end

      # A miniature of a screen: each word becomes a small colored bar.
      # Much cheaper than text and still recognisable at thumbnail size.
      def paint_minimap(pt, scr, x, y, width, height)
        cw = width / scr.cols.to_f
        ch = height / scr.rows.to_f
        bar_h = [ch * 0.7, 1].max
        minimap_runs(scr).each do |row, c1, c2, color|
          pt.fill_rect(x + (c1 * cw), y + (row * ch), (c2 - c1 + 1) * cw, bar_h, PALETTE[color] || PALETTE[:green], 0.9)
        end
      end

      # [[row, first_col, last_col, color], ...] for each word on the screen.
      def minimap_runs(scr) = scr.memo(:minimap_runs) { find_minimap_runs(scr) }

      def find_minimap_runs(scr)
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
