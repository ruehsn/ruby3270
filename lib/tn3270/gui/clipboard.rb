# frozen_string_literal: true

require "open3"

module Tn3270
  module Gui
    # LibUI has no clipboard API, so use the platform's command-line tools.
    module Clipboard
      module_function

      def copy(text)
        cmd = if Config::WINDOWS then ["clip"]
              elsif Config::MAC then ["pbcopy"]
              else ["xclip", "-selection", "clipboard"]
              end
        # clip.exe reads the console code page; UTF-16LE with a BOM is reliable.
        data = Config::WINDOWS ? "﻿#{text}".encode("UTF-16LE") : text
        Open3.capture2(*cmd, stdin_data: data, binmode: true)
        true
      rescue SystemCallError
        false
      end

      def paste
        cmd = if Config::WINDOWS then ["powershell", "-NoProfile", "-Command", "Get-Clipboard -Raw"]
              elsif Config::MAC then ["pbpaste"]
              else ["xclip", "-selection", "clipboard", "-o"]
              end
        out, = Open3.capture2(*cmd)
        out.encode("UTF-8", invalid: :replace, undef: :replace).delete("\r")
      rescue SystemCallError
        ""
      end
    end
  end
end
