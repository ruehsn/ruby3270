# frozen_string_literal: true

require_relative "theme"

module Tn3270
  module Gui
    # Keeps a TerminalWindow the shape of its screen (Windows, "Lock Window
    # Shape to the Screen"), so there is no empty band beside or below it.
    # Included into TerminalWindow.
    module WindowShape
      include Theme

      # Pixels per drawing unit (display scaling).
      def px_scale
        return 1.0 unless @area_size && Win32.available? && @area_size[0].positive?

        Win32.client_size(@area.control)[0] / @area_size[0].to_f
      end

      # Screen x (pixels) -> drawing area x.
      def area_x(px) = (px - Win32.client_to_screen(@area.control, 0, 0)[0]) / px_scale

      # Height of the parts of the drawing area that aren't the screen grid
      # (title bar, margins, status bar), in drawing units.
      def chrome_h = header_h + 4 + STATUS_H + 4 + (2 * SCREEN_PAD)

      # Width beside the screen: the snippets sidebar and the margins.
      def side_w = panel_w + (2 * SCREEN_PAD)

      # Width / height of the screen grid at any font size.
      def grid_ratio
        rows, cols = grid_size
        fm = FontMetrics.for(@config["font"])
        (cols * fm[:advance]) / (rows * fm[:line])
      end

      # [extra window width, extra window height, pixels per drawing unit]:
      # what the window adds around the drawing area (borders, menu bar, key
      # bar), measured now, and the display scaling.
      def window_extras
        return nil unless @area_size

        win_w, win_h = Win32.window_size(@window)
        area_w, area_h = Win32.client_size(@area.control)
        return nil unless area_w.positive? && @area_size[0].positive?

        [win_w - area_w, win_h - area_h, area_w / @area_size[0].to_f]
      end

      # Outer window height that fits the screen exactly at a given outer width (and back).
      def shaped_height(width, extras)
        extra_w, extra_h, scale = extras
        ((width - extra_w - (side_w * scale)) / grid_ratio) + (chrome_h * scale) + extra_h
      end

      def shaped_width(height, extras)
        extra_w, extra_h, scale = extras
        ((height - extra_h - (chrome_h * scale)) * grid_ratio) + extra_w + (side_w * scale)
      end

      WMSZ_TOP = [3, 4, 5].freeze # top, top-left, top-right
      WMSZ_TOP_BOTTOM = [3, 6].freeze

      # While the user drags an edge: keep the window the shape of the screen.
      # Dragging the top or bottom edge sets the width; any other edge or corner
      # sets the height.
      def shaped_rect(edge, rect)
        return nil unless @config["lock_ratio"] && (extras = window_extras)

        left, top, right, bottom = rect
        max_w, max_h = Win32.max_window_size
        if WMSZ_TOP_BOTTOM.include?(edge)
          height = bottom - top
          width = shaped_width(height, extras)
          # Too wide for Windows to allow: the width decides instead.
          height = shaped_height(width = max_w, extras) if width > max_w
          right = left + width
          WMSZ_TOP.include?(edge) ? top = bottom - height : bottom = top + height
        else
          width = right - left
          height = shaped_height(width, extras)
          # Too tall for Windows to allow: the height decides instead.
          width = shaped_width(height = max_h, extras) if height > max_h
          [1, 4, 7].include?(edge) ? left = right - width : right = left + width # left-side edges
          WMSZ_TOP.include?(edge) ? top = bottom - height : bottom = top + height
        end
        [left, top, right, bottom]
      end

      # Snaps the window to the screen's shape (not when maximized). Normally the
      # width stays and the height follows; keep: :height (the snippets sidebar
      # opening or closing) keeps the height and grows or shrinks the width, so
      # the screen itself doesn't change size.
      def fit_window_to_screen(keep: :width)
        @shaped_for = grid_size
        return unless @config["lock_ratio"] && Win32.available? && !Win32.maximized?(@window)
        return unless (extras = window_extras)

        width, height = Win32.window_size(@window)
        if keep == :height
          width = shaped_width(height, extras)
        else
          height = shaped_height(width, extras)
        end
        # Keep it on the screen: too tall means narrower, and move it up if needed.
        area_x, area_y, area_w, area_h = Win32.work_area(@window)
        height = shaped_height(width = area_w, extras) if width > area_w
        width = shaped_width(height = area_h, extras) if height > area_h
        left, top = Win32.window_position(@window)
        left = left.clamp(area_x, area_x + area_w - width)
        top = top.clamp(area_y, area_y + area_h - height)
        Win32.place(@window, left, top, width, height)
      end

      def set_lock_ratio(on)
        set_option("lock_ratio", on)
        @reshape = true
      end
    end
  end
end
