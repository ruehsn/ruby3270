# frozen_string_literal: true

require "fiddle"
require_relative "config"

module Tn3270
  module Gui
    # The monospaced fonts installed on this computer, for the font picker.
    # On Windows they come from GDI (fonts it flags as fixed pitch); elsewhere
    # a list of common ones is offered.
    module Fonts
      COMMON = ["DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", "Ubuntu Mono", "Menlo", "Monaco",
                "Courier New", "Courier"].freeze
      FIXED_PITCH = 1
      DEFAULT_CHARSET = 1
      SYMBOL_CHARSET = 2
      RASTER_FONTTYPE = 1 # old bitmap fonts; the text engine libui uses can't draw them

      module_function

      # Sorted family names, with `current` included even if it isn't found.
      def monospaced(current = nil)
        @monospaced ||= (Config::WINDOWS ? windows_fonts : COMMON).uniq.sort_by(&:downcase)
        current.to_s.empty? || @monospaced.include?(current) ? @monospaced : [current, *@monospaced]
      rescue StandardError
        COMMON
      end

      # Asks GDI for every font family; keeps the fixed-pitch ones, minus
      # bitmap and symbol fonts. Names starting with "@" are the vertical-text
      # variants of Asian fonts.
      def windows_fonts
        gdi = Fiddle.dlopen("gdi32")
        user = Fiddle.dlopen("user32")
        p = Fiddle::TYPE_VOIDP
        get_dc = Fiddle::Function.new(user["GetDC"], [p], p)
        release_dc = Fiddle::Function.new(user["ReleaseDC"], [p, p], Fiddle::TYPE_INT)
        enum = Fiddle::Function.new(gdi["EnumFontFamiliesExW"], [p, p, p, Fiddle::TYPE_INTPTR_T, Fiddle::TYPE_INT], Fiddle::TYPE_INT)

        names = []
        # LOGFONTW: lfCharSet is byte 23, lfPitchAndFamily byte 27, and
        # lfFaceName (32 UTF-16 chars) starts at byte 28.
        callback = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_INT, [p, p, Fiddle::TYPE_INT, Fiddle::TYPE_INTPTR_T]) do |font, _metrics, type, _data|
          f = Fiddle::Pointer.new(font)
          face = f[28, 64].force_encoding("UTF-16LE").encode("UTF-8")[/\A[^\0]*/]
          fixed = (f[27, 1].unpack1("C") & 3) == FIXED_PITCH
          usable = type.nobits?(RASTER_FONTTYPE) && f[23, 1].unpack1("C") != SYMBOL_CHARSET
          names << face if fixed && usable && !face.empty? && !face.start_with?("@")
          1 # keep going
        end
        query = Fiddle::Pointer.malloc(92, Fiddle::RUBY_FREE)
        query[0, 92] = "\0" * 92
        query[23, 1] = [DEFAULT_CHARSET].pack("C") # every character set, every family
        dc = get_dc.call(nil)
        enum.call(dc, query, callback, 0, 0)
        release_dc.call(nil, dc)
        names
      end
    end
  end
end
