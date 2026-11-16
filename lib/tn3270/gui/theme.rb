# frozen_string_literal: true

require_relative "config"

module Tn3270
  module Gui
    # Colors ([r, g, b]) and sizes (drawing units) shared by everything the
    # windows draw. Included wherever they are used.
    module Theme
      # 3270 color name -> RGB
      PALETTE = {
        neutral: [0xE0, 0xE0, 0xE0], blue: [0x6C, 0x9B, 0xFF], red: [0xFF, 0x55, 0x55],
        pink: [0xFF, 0x79, 0xE6], green: [0x4C, 0xE0, 0x6A], turquoise: [0x3F, 0xE0, 0xE0],
        yellow: [0xFF, 0xE0, 0x4C], white: [0xF4, 0xF4, 0xF4], black: [0x00, 0x00, 0x00],
        deep_blue: [0x5A, 0x6C, 0xF0], orange: [0xFF, 0xA5, 0x33], purple: [0xB3, 0x7D, 0xFF],
        pale_green: [0xA8, 0xF0, 0xA8], pale_turquoise: [0xAF, 0xEE, 0xEE], grey: [0xA0, 0xA0, 0xA0]
      }.freeze
      BACKGROUND = [0x0B, 0x0E, 0x12].freeze

      STATUS_BG = [0x1C, 0x22, 0x2B].freeze
      CURSOR = [0xFF, 0xFF, 0xFF].freeze
      SELECTION = [0x4C, 0x8D, 0xFF].freeze
      ICON_FG = [0xC8, 0xD2, 0xE0].freeze
      ONLINE = [0x3D, 0xD6, 0x5C].freeze
      CONNECTING = [0xFF, 0xB0, 0x2E].freeze
      OFFLINE = [0x7A, 0x84, 0x94].freeze
      CAPS_ON = [0xFF, 0xC4, 0x3D].freeze
      CROSSHAIR = [0x8C, 0xB4, 0xFF].freeze
      FIND_HIT = [0xFF, 0xD2, 0x3F].freeze
      WHITE = [0xFF, 0xFF, 0xFF].freeze

      # Title bar (menus in the title bar, VS Code style)
      TITLE_H = 32

      TITLE_BG = [0x18, 0x1D, 0x25].freeze
      TITLE_FG = [0xCC, 0xD4, 0xE0].freeze
      TITLE_MUTED = [0x8A, 0x96, 0xA8].freeze
      CLOSE_HOVER = [0xE8, 0x11, 0x23].freeze
      BUTTON_W = 46
      STATUS_H = 26 # status bar height in pixels
      STATUS_FONT_SIZE = 9.5
      TAB_STRIP_H = 32 # without the custom title bar, the tabs get a row of their own
      CAPTION_MIN = 48 # title bar width kept free of tabs, for dragging the window
      UI_FONT = Config::WINDOWS ? "Segoe UI" : "Sans"
      UI_SIZE = 9.0
      SCREEN_PAD = 5 # blank margin (pixels) around the mainframe screen

      TAB_HOVER = [0xFF, 0xFF, 0xFF].freeze

      # Colors a session's tab can be given (a connection's "color"), to tell
      # sessions apart at a glance: red for production, say.
      TAB_COLORS = {
        "red" => [0xE5, 0x48, 0x4D], "orange" => [0xF0, 0x8C, 0x2E], "yellow" => [0xE6, 0xC2, 0x29],
        "green" => [0x3F, 0xB9, 0x6B], "blue" => [0x4C, 0x8D, 0xFF], "purple" => [0xA3, 0x71, 0xF7]
      }.freeze

      # Background while the keyboard is locked by an error (X -f), until Reset.
      LOCKED_BACKGROUND = [0x2E, 0x0C, 0x10].freeze
    end
  end
end
