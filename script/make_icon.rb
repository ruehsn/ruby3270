# frozen_string_literal: true

# Draws the app icon and writes assets/tn3270.ico (16-256 px) and assets/tn3270.png.
#   ruby script/make_icon.rb
#
# The design: a dark rounded tile showing a tiny 3270 screen, with a blue
# title line, green text lines and a bright block cursor. Shapes are drawn
# with signed distance functions so edges are anti-aliased at every size,
# and small sizes snap to whole pixels so they stay crisp.
require "chunky_png"

SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256].freeze
OUT = File.expand_path("../assets", __dir__)

BG_TOP = [0x22, 0x2D, 0x40].freeze
BG_BOTTOM = [0x0B, 0x0E, 0x14].freeze
EDGE = [0x3A, 0x4A, 0x63].freeze
BLUE = [0x6C, 0x9B, 0xFF].freeze
GREEN = [0x4C, 0xE0, 0x6A].freeze
CURSOR = [0xF4, 0xFF, 0xF6].freeze
TURQUOISE = [0x3F, 0xC8, 0xD0].freeze

# Signed distance from (px, py) to a rounded rectangle.
def rrect_sdf(px, py, x0, y0, x1, y1, r)
  cx = (x0 + x1) / 2.0
  cy = (y0 + y1) / 2.0
  hx = ((x1 - x0) / 2.0) - r
  hy = ((y1 - y0) / 2.0) - r
  qx = (px - cx).abs - hx
  qy = (py - cy).abs - hy
  outside = Math.sqrt([qx, 0].max**2 + [qy, 0].max**2)
  outside + [[qx, qy].max, 0].min - r
end

def coverage(d) = (0.5 - d).clamp(0.0, 1.0)

def blend(dst, src, a)
  dst.each_index.map { |i| (dst[i] * (1 - a)) + (src[i] * a) }
end

def render(n)
  u = n / 16.0
  snap = n <= 48
  s = ->(v) { snap ? (v * u).round.to_f : v * u }

  # Shapes in 16-unit design space: [x0, y0, x1, y1, radius, color]
  bar_h = n <= 20 ? 2 : 1.6
  bars = [
    [3, 3, 13, 3 + bar_h, BLUE],                 # title line
    [3, 6, 11.5, 6 + bar_h, GREEN],              # text
    [3, 9, 7.5, 9 + bar_h, GREEN],               # text
    [8.6, 9, 10.6, 9 + bar_h, CURSOR],           # block cursor
    [3, 12.4, 13, 12.4 + [bar_h * 0.5, 1 / u].max, TURQUOISE] # status line (OIA)
  ]
  bars = bars.map { |x0, y0, x1, y1, c| [s.(x0), s.(y0), s.(x1), s.(y1), c] }
  tile_r = 3.4 * u
  bar_r = [0.35 * u, 0.5].max

  img = ChunkyPNG::Image.new(n, n, ChunkyPNG::Color::TRANSPARENT)
  n.times do |y|
    n.times do |x|
      px = x + 0.5
      py = y + 0.5
      d = rrect_sdf(px, py, 0.5, 0.5, n - 0.5, n - 0.5, tile_r)
      alpha = coverage(d)
      next if alpha <= 0

      t = py / n
      col = blend(BG_TOP, BG_BOTTOM, t)
      # thin lighter rim just inside the edge
      rim = coverage((d + [u * 0.6, 1.0].max).abs - 0.5) * 0.55 if n >= 24
      col = blend(col, EDGE, rim) if rim
      bars.each do |x0, y0, x1, y1, c|
        a = coverage(rrect_sdf(px, py, x0, y0, x1, y1, bar_r))
        col = blend(col, c, a) if a.positive?
      end
      r, g, b = col.map { |v| v.round.clamp(0, 255) }
      img[x, y] = ChunkyPNG::Color.rgba(r, g, b, (alpha * 255).round)
    end
  end
  img
end

# ICO with PNG-compressed entries (supported since Windows Vista).
def write_ico(path, images)
  blobs = images.map { |img| img.to_blob(:best_compression) }
  header = [0, 1, images.size].pack("v3")
  offset = 6 + (16 * images.size)
  dir = images.each_with_index.map do |img, i|
    w = img.width >= 256 ? 0 : img.width
    entry = [w, w, 0, 0, 1, 32, blobs[i].bytesize, offset].pack("C4v2V2")
    offset += blobs[i].bytesize
    entry
  end
  File.binwrite(path, header + dir.join + blobs.join)
end

Dir.mkdir(OUT) unless Dir.exist?(OUT)
images = SIZES.map { |n| render(n) }
write_ico(File.join(OUT, "tn3270.ico"), images)
images.last.save(File.join(OUT, "tn3270.png"))
# Preview sheet of every size, for checking the design.
sheet = ChunkyPNG::Image.new(SIZES.sum + (10 * SIZES.size), 256, ChunkyPNG::Color.rgb(240, 240, 240))
x = 0
images.each do |img|
  sheet.compose!(img, x, 0)
  x += img.width + 10
end
sheet.save(File.join(OUT, "icon-preview.png"))
puts "wrote #{OUT}/tn3270.ico"
