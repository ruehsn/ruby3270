# frozen_string_literal: true

require "fiddle"
require "tmpdir"
require_relative "config"
require_relative "win32"

module Tn3270
  module Gui
    # A picture of a whole window (Windows only): title bar, tabs, screen,
    # key bar and status bar.
    #
    # It is put together from two parts, because no single way gets all of it:
    # Windows draws the window's frame and its ordinary controls (the key
    # bar) into a bitmap, but what the app draws itself with Direct2D comes
    # out blank that way (and, on some computers, even when copied from the
    # screen). So the app draws its own area again, into the same bitmap,
    # through an ImagePainter. Nothing has to be on the screen for it: the
    # window may be covered or partly off the screen.
    #
    #   shot = Screenshot.grab(window, area_control, [units_wide, units_high]) { |painter| draw_with(painter) }
    #   File.binwrite("screen.png", shot.png)
    #   Clipboard.copy_image(shot)
    module Screenshot
      # png: the picture as PNG file bytes. dib: the same picture as a
      # Windows bitmap (header + pixels), which is what most programs paste.
      Shot = Struct.new(:png, :dib, :width, :height)

      PW_RENDERFULLCONTENT = 2
      DWMWA_EXTENDED_FRAME_BOUNDS = 9
      SRCCOPY = 0x00CC0020
      PNG_ENCODER = [0x557CF406, 0x1A04, 0x11D3, 0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E].pack("LSSC8").freeze

      P = Fiddle::TYPE_VOIDP
      I = Fiddle::TYPE_INT
      F = Fiddle::TYPE_FLOAT

      module_function

      def available? = Win32.available?

      def lib(name) = (@libs ||= {})[name] ||= Fiddle.dlopen(name)

      def fn(dll, name, args, ret = I)
        (@fns ||= {})[name] ||= Fiddle::Function.new(lib(dll)[name], args, ret)
      end

      # `area` is the control the app draws in and `units` its size in
      # drawing units; the block gets an ImagePainter to draw that area with.
      # `controls` are ordinary controls in the window (the key bar): each is
      # asked to draw itself, as the picture of the whole window sometimes
      # leaves a few of their buttons out.
      # Returns a Shot, or nil if the picture can't be taken.
      def grab(window, area, units, controls: [])
        return nil unless available?

        gdiplus
        hwnd = Win32.hwnd(window)
        outer = Win32.window_rect(window)
        frame = visible_rect(hwnd) || outer
        screen = fn("user32", "GetDC", [P], P).call(nil)
        full = bitmap(screen, outer[2] - outer[0], outer[3] - outer[1])
        fn("user32", "PrintWindow", [P, P, I]).call(hwnd, full[:dc], PW_RENDERFULLCONTENT)
        controls.each { |control| print_control(control, full[:dc], outer) }

        ax, ay = Win32.client_to_screen(area, 0, 0)
        aw, ah = Win32.client_size(area)
        painter = ImagePainter.new(full[:dc], ax - outer[0], ay - outer[1], aw, ah, aw / units[0].to_f)
        begin
          yield painter
        ensure
          painter.finish
        end

        # Without the invisible borders Windows keeps round a window for resizing.
        width = frame[2] - frame[0]
        height = frame[3] - frame[1]
        shot = bitmap(screen, width, height)
        fn("gdi32", "BitBlt", [P, I, I, I, I, P, I, I, I])
          .call(shot[:dc], 0, 0, width, height, full[:dc], frame[0] - outer[0], frame[1] - outer[1], SRCCOPY)
        Shot.new(png_of(shot[:bitmap]), dib_of(shot, width, height), width, height)
      rescue Fiddle::DLError
        nil
      ensure
        [full, shot].compact.each { |b| release(b) }
        fn("user32", "ReleaseDC", [P, P]).call(nil, screen) if screen
      end

      # Has a control draw itself (and its children) at its place in the picture.
      def print_control(control, dc, outer)
        x, y = Win32.client_to_screen(control, 0, 0)
        origin = fn("gdi32", "SetViewportOrgEx", [P, I, I, P])
        origin.call(dc, x - outer[0], y - outer[1], nil)
        fn("user32", "PrintWindow", [P, P, I]).call(Win32.hwnd(control), dc, 0)
      ensure
        origin&.call(dc, 0, 0, nil)
      end

      # The part of the window you can see: [left, top, right, bottom], or nil.
      def visible_rect(hwnd)
        rect = Fiddle::Pointer.malloc(16, Fiddle::RUBY_FREE)
        ok = fn("dwmapi", "DwmGetWindowAttribute", [P, I, P, I]).call(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, rect, 16).zero?
        ok ? rect[0, 16].unpack("l4") : nil
      rescue Fiddle::DLError
        nil
      end

      # A bitmap to draw into: { dc:, bitmap:, old: }.
      def bitmap(screen, width, height)
        dc = fn("gdi32", "CreateCompatibleDC", [P], P).call(screen)
        bmp = fn("gdi32", "CreateCompatibleBitmap", [P, I, I], P).call(screen, width, height)
        { dc: dc, bitmap: bmp, old: fn("gdi32", "SelectObject", [P, P], P).call(dc, bmp) }
      end

      def release(bmp)
        fn("gdi32", "SelectObject", [P, P], P).call(bmp[:dc], bmp[:old])
        fn("gdi32", "DeleteObject", [P]).call(bmp[:bitmap])
        fn("gdi32", "DeleteDC", [P]).call(bmp[:dc])
      end

      # BITMAPINFOHEADER + 24-bit pixels, bottom row first (the CF_DIB layout).
      def dib_of(bmp, width, height)
        stride = ((width * 3) + 3) & ~3
        header = [40, width, height, 1, 24, 0, stride * height, 0, 0, 0, 0].pack("LllSSLLllLL")
        info = Fiddle::Pointer.malloc(40, Fiddle::RUBY_FREE)
        info[0, 40] = header
        bits = Fiddle::Pointer.malloc(stride * height, Fiddle::RUBY_FREE)
        # (The bitmap mustn't be selected into a DC while GetDIBits reads it.)
        fn("gdi32", "SelectObject", [P, P], P).call(bmp[:dc], bmp[:old])
        fn("gdi32", "GetDIBits", [P, P, I, I, P, P, I]).call(bmp[:dc], bmp[:bitmap], 0, height, bits, info, 0)
        header + bits[0, stride * height]
      end

      # GDI+ writes the PNG (to a temporary file, read back and removed).
      def png_of(hbitmap)
        image = out_pointer { |ptr| fn("gdiplus", "GdipCreateBitmapFromHBITMAP", [P, P, P]).call(hbitmap, nil, ptr) } or return nil
        path = File.join(Dir.tmpdir, "ruby3270-shot-#{Process.pid}-#{rand(1 << 32).to_s(16)}.png")
        begin
          saved = fn("gdiplus", "GdipSaveImageToFile", [P, P, P, P]).call(image, Win32.wide(path), Fiddle::Pointer[PNG_ENCODER.dup], nil)
          saved.zero? ? File.binread(path) : nil
        ensure
          fn("gdiplus", "GdipDisposeImage", [P]).call(image)
          File.delete(path) if File.exist?(path)
        end
      end

      # Calls the block with somewhere for a GDI+ function to put an object
      # it makes; returns that object, or nil if the function failed.
      def out_pointer
        slot = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
        slot[0, 8] = "\0" * 8
        return nil unless yield(slot).zero?

        address = slot[0, 8].unpack1("Q")
        address.zero? ? nil : Fiddle::Pointer.new(address)
      end

      # Starts GDI+ once for the life of the program.
      def gdiplus
        return if @gdiplus

        token = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
        input = Fiddle::Pointer[[1, 0, 0, 0].pack("Lx4QLL")] # GdiplusStartupInput: version 1
        fn("gdiplus", "GdiplusStartup", [P, P, P]).call(token, input, nil)
        @gdiplus = true
      end

      # Draws what a Painter draws, into a bitmap instead of a window (with
      # GDI+). It takes the same calls, in the same drawing units, so whatever
      # draws a window can draw its picture.
      class ImagePainter
        S = Screenshot
        ANTIALIAS = 4 # smooth shapes; text at its true widths, so columns line up
        NO_WRAP_NO_CLIP = 0x1000 | 0x4000 | 0x800 | 0x4 # ...and trailing spaces count, glyphs may overhang
        ALIGN = { left: 0, center: 1, right: 2 }.freeze
        ROUND_CAP = 2

        # dc: the bitmap's device context. x, y, width, height: where the
        # drawing area is in it, in pixels. scale: pixels per drawing unit.
        def initialize(dc, x, y, width, height, scale)
          @graphics = S.out_pointer { |ptr| S.fn("gdiplus", "GdipCreateFromHDC", [P, P]).call(dc, ptr) }
          @brushes = {}
          @fonts = {}
          @formats = {}
          return unless @graphics

          S.fn("gdiplus", "GdipSetClipRectI", [P, I, I, I, I, I]).call(@graphics, x, y, width, height, 0)
          S.fn("gdiplus", "GdipTranslateWorldTransform", [P, F, F, I]).call(@graphics, x.to_f, y.to_f, 0)
          S.fn("gdiplus", "GdipScaleWorldTransform", [P, F, F, I]).call(@graphics, scale, scale, 0)
          S.fn("gdiplus", "GdipSetSmoothingMode", [P, I]).call(@graphics, ANTIALIAS)
          S.fn("gdiplus", "GdipSetTextRenderingHint", [P, I]).call(@graphics, ANTIALIAS)
        end

        # (A Painter is given a libui context for each frame; there is none here.)
        attr_accessor :context

        def fill_rect(x, y, w, h, rgb, alpha = 1.0)
          S.fn("gdiplus", "GdipFillRectangle", [P, P, F, F, F, F]).call(@graphics, brush(rgb, alpha), x, y, w, h) if @graphics
        end

        def fill_rects(rects, rgb, alpha = 1.0) = rects.each { |x, y, w, h| fill_rect(x, y, w, h, rgb, alpha) }

        def stroke_rect(x, y, w, h, rgb, thickness = 1.0, alpha = 1.0)
          pen(rgb, alpha, thickness) { |p| S.fn("gdiplus", "GdipDrawRectangle", [P, P, F, F, F, F]).call(@graphics, p, x, y, w, h) }
        end

        def fill_circle(cx, cy, r, rgb, alpha = 1.0)
          return unless @graphics

          S.fn("gdiplus", "GdipFillEllipse", [P, P, F, F, F, F]).call(@graphics, brush(rgb, alpha), cx - r, cy - r, 2 * r, 2 * r)
        end

        def stroke_circle(cx, cy, r, rgb, thickness = 1.0, alpha = 1.0)
          pen(rgb, alpha, thickness) do |p|
            S.fn("gdiplus", "GdipDrawEllipse", [P, P, F, F, F, F]).call(@graphics, p, cx - r, cy - r, 2 * r, 2 * r)
          end
        end

        # points: [x1, y1, x2, y2, ...]
        def polyline(points, rgb, thickness = 1.0, alpha = 1.0, cap: :flat)
          pen(rgb, alpha, thickness) do |p|
            S.fn("gdiplus", "GdipSetPenLineCap197819", [P, I, I, I]).call(p, ROUND_CAP, ROUND_CAP, ROUND_CAP) if cap == :round
            S.fn("gdiplus", "GdipDrawLines", [P, P, P, I]).call(@graphics, p, Fiddle::Pointer[points.pack("f*")], points.size / 2)
          end
        end

        def text(x, y, width, str, rgb, family, size, bold: false, align: :left, alpha: 1.0)
          return if str.nil? || str.empty? || !@graphics

          wide = str.encode("UTF-16LE")
          box = Fiddle::Pointer[[x, y, width.negative? ? 0 : width, 0].pack("f4")]
          S.fn("gdiplus", "GdipDrawString", [P, P, I, P, P, P, P])
           .call(@graphics, Fiddle::Pointer[wide], wide.bytesize / 2, font(family, size, bold), box, format(align), brush(rgb, alpha))
        end

        # Lets go of everything GDI+ made for this picture.
        def finish
          @brushes.each_value { |b| S.fn("gdiplus", "GdipDeleteBrush", [P]).call(b) }
          @fonts.each_value { |f| S.fn("gdiplus", "GdipDeleteFont", [P]).call(f) if f }
          @formats.each_value { |f| S.fn("gdiplus", "GdipDeleteStringFormat", [P]).call(f) if f }
          S.fn("gdiplus", "GdipDeleteGraphics", [P]).call(@graphics) if @graphics
          @graphics = nil
        end

        private

        P = Screenshot::P
        I = Screenshot::I
        F = Screenshot::F

        def argb(rgb, alpha)
          value = ((alpha.clamp(0.0, 1.0) * 255).round << 24) | (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]
          [value].pack("L").unpack1("l")
        end

        def brush(rgb, alpha)
          color = argb(rgb, alpha)
          @brushes[color] ||= S.out_pointer { |ptr| S.fn("gdiplus", "GdipCreateSolidFill", [I, P]).call(color, ptr) }
        end

        def pen(rgb, alpha, thickness)
          return unless @graphics

          pen = S.out_pointer { |ptr| S.fn("gdiplus", "GdipCreatePen1", [I, F, I, P]).call(argb(rgb, alpha), thickness.to_f, 0, ptr) }
          return unless pen

          begin
            yield pen
          ensure
            S.fn("gdiplus", "GdipDeletePen", [P]).call(pen)
          end
        end

        # A font size is in points; a drawing unit is 1/96 inch.
        def font(family, size, bold)
          @fonts.fetch([family, size, bold]) do |key|
            fam = S.out_pointer { |ptr| S.fn("gdiplus", "GdipCreateFontFamilyFromName", [P, P, P]).call(Win32.wide(family), nil, ptr) } ||
                  S.out_pointer { |ptr| S.fn("gdiplus", "GdipGetGenericFontFamilyMonospace", [P]).call(ptr) }
            @fonts[key] = fam && S.out_pointer do |ptr|
              S.fn("gdiplus", "GdipCreateFont", [P, F, I, I, P]).call(fam, size * 96.0 / 72.0, bold ? 1 : 0, 2, ptr) # 2: pixels
            end
          end
        end

        def format(align)
          @formats.fetch(align) do
            # The "typographic" format: characters at their true widths, with
            # none of the padding GDI+ otherwise adds (lines came out 3% too long).
            plain = S.out_pointer { |ptr| S.fn("gdiplus", "GdipStringFormatGetGenericTypographic", [P]).call(ptr) }
            fmt = plain && S.out_pointer { |ptr| S.fn("gdiplus", "GdipCloneStringFormat", [P, P]).call(plain, ptr) }
            if fmt
              S.fn("gdiplus", "GdipSetStringFormatFlags", [P, I]).call(fmt, NO_WRAP_NO_CLIP)
              S.fn("gdiplus", "GdipSetStringFormatAlign", [P, I]).call(fmt, ALIGN.fetch(align))
            end
            @formats[align] = fmt
          end
        end
      end
    end
  end
end
