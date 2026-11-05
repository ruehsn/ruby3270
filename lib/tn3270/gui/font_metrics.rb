# frozen_string_literal: true

require "fiddle"

module Tn3270
  module Gui
    # Measures how wide one character and how tall one line really are for a
    # font, per point of font size, by asking LibUI to lay out sample text.
    # Font sizes are in points but the drawing area is in pixels (1pt = 1.33px
    # on Windows), so guessing these ratios makes text overflow its cells.
    module FontMetrics
      # Used if measuring fails (roughly Consolas on Windows).
      FALLBACK = { advance: 0.733, line: 1.56 }.freeze
      SAMPLE_CHARS = 100
      SAMPLE_LINES = 10
      SAMPLE_SIZE = 20.0

      @cache = {}

      module_function

      # { advance: px per pt per char, line: px per pt per line }. Must run after
      # LibUI is initialised (e.g. inside a draw handler). Cached per font.
      def for(family)
        @cache[family] ||= begin
          width, = extents(family, "M" * SAMPLE_CHARS)
          _, height = extents(family, Array.new(SAMPLE_LINES, "M").join("\n"))
          if width.positive? && height.positive?
            { advance: width / SAMPLE_CHARS / SAMPLE_SIZE, line: height / SAMPLE_LINES / SAMPLE_SIZE }
          else
            FALLBACK
          end
        rescue StandardError
          FALLBACK
        end
      end

      # Width in pixels of `text` at a font size (cached).
      def text_width(family, size, text)
        @widths ||= {}
        @widths[[family, size, text]] ||= begin
          extents(family, text, size: size)[0]
        rescue StandardError
          text.size * size * 0.55
        end
      end

      def extents(family, text, size: SAMPLE_SIZE)
        str = ::LibUI.new_attributed_string(text)
        family_ptr = Fiddle::Pointer["#{family}\0"]
        font = ::LibUI::FFI::FontDescriptor.malloc
        font.Family = family_ptr
        font.Size = size
        font.Weight = ::LibUI::TextWeightNormal
        font.Italic = ::LibUI::TextItalicNormal
        font.Stretch = ::LibUI::TextStretchNormal
        params = ::LibUI::FFI::DrawTextLayoutParams.malloc
        params.String = str
        params.DefaultFont = font
        params.Width = -1 # no wrapping
        params.Align = ::LibUI::DrawTextAlignLeft
        layout = ::LibUI.draw_new_text_layout(params)
        w = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE)
        h = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE)
        ::LibUI.draw_text_layout_extents(layout, w, h)
        [w[0, Fiddle::SIZEOF_DOUBLE].unpack1("d"), h[0, Fiddle::SIZEOF_DOUBLE].unpack1("d")]
      ensure
        ::LibUI.draw_free_text_layout(layout) if layout
        ::LibUI.free_attributed_string(str) if str
      end
    end
  end
end
