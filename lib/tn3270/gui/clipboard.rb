# frozen_string_literal: true

require "fiddle"
require "open3"
require_relative "config"

module Tn3270
  module Gui
    # The system clipboard. On Windows it talks to the clipboard API directly
    # (Unicode text, no helper programs); elsewhere it uses pbcopy / xclip.
    module Clipboard
      CF_UNICODETEXT = 13
      GMEM_MOVEABLE = 0x2

      module_function

      def copy(text)
        Config::WINDOWS ? win_copy(text.to_s) : tool_copy(text.to_s)
      rescue StandardError
        false
      end

      def paste
        (Config::WINDOWS ? win_paste : tool_paste).to_s.delete("\r")
      rescue StandardError
        ""
      end

      # ---- Windows ---------------------------------------------------------------

      def api
        @api ||= begin
          u = Fiddle.dlopen("user32")
          k = Fiddle.dlopen("kernel32")
          ptr = Fiddle::TYPE_VOIDP
          int = Fiddle::TYPE_INT
          size = Fiddle::TYPE_SIZE_T
          fn = ->(lib, name, args, ret) { Fiddle::Function.new(lib[name], args, ret) }
          {
            open: fn.(u, "OpenClipboard", [ptr], int), close: fn.(u, "CloseClipboard", [], int),
            empty: fn.(u, "EmptyClipboard", [], int), set: fn.(u, "SetClipboardData", [int, ptr], ptr),
            get: fn.(u, "GetClipboardData", [int], ptr), alloc: fn.(k, "GlobalAlloc", [int, size], ptr),
            lock: fn.(k, "GlobalLock", [ptr], ptr), unlock: fn.(k, "GlobalUnlock", [ptr], int),
            size: fn.(k, "GlobalSize", [ptr], size), free: fn.(k, "GlobalFree", [ptr], ptr)
          }
        end
      end

      # Another program may hold the clipboard for a moment; try a few times.
      def with_clipboard
        opened = 10.times.any? do
          api[:open].call(nil).nonzero? || (sleep(0.02) && false)
        end
        return nil unless opened

        begin
          yield
        ensure
          api[:close].call
        end
      end

      def win_copy(text)
        data = "#{text.gsub(/\r?\n/, "\r\n")}\0".encode("UTF-16LE").b
        with_clipboard do
          api[:empty].call
          handle = api[:alloc].call(GMEM_MOVEABLE, data.bytesize)
          ptr = api[:lock].call(handle)
          ptr[0, data.bytesize] = data
          api[:unlock].call(handle)
          if api[:set].call(CF_UNICODETEXT, handle).null?
            api[:free].call(handle)
            false
          else
            true # the clipboard owns the memory now
          end
        end || false
      end

      def win_paste
        with_clipboard do
          handle = api[:get].call(CF_UNICODETEXT)
          next "" if handle.null?

          ptr = api[:lock].call(handle)
          begin
            bytes = ptr[0, api[:size].call(handle)]
            text = bytes.force_encoding("UTF-16LE")
            text = text[0, text.index("\0".encode("UTF-16LE")) || text.size]
            text.encode("UTF-8", invalid: :replace, undef: :replace)
          ensure
            api[:unlock].call(handle)
          end
        end || ""
      end

      # ---- macOS / Linux -------------------------------------------------------

      def tool_copy(text)
        cmd = Config::MAC ? ["pbcopy"] : ["xclip", "-selection", "clipboard"]
        Open3.capture2(*cmd, stdin_data: text)
        true
      end

      def tool_paste
        cmd = Config::MAC ? ["pbpaste"] : ["xclip", "-selection", "clipboard", "-o"]
        out, = Open3.capture2(*cmd)
        out.encode("UTF-8", invalid: :replace, undef: :replace)
      end
    end
  end
end
