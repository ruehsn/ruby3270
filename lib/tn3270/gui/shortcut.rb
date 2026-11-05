# frozen_string_literal: true

require "rbconfig"
require_relative "config"

module Tn3270
  module Gui
    # Desktop shortcuts (.lnk) that open the emulator on a saved session:
    #   rubyw.exe bin\tn3270 --session "Work mainframe"
    # Windows only. Every method returns nil if shortcuts can't be made here.
    module Shortcut
      ROOT = File.expand_path("../../..", __dir__)
      LAUNCHER = File.join(ROOT, "bin", "tn3270")
      ICON = File.join(ROOT, "assets", "tn3270.ico")
      MARKER = "--session" # only shortcuts with this in their arguments are ours to replace or remove

      module_function

      # Creates or updates the shortcut for a connection. Returns its path.
      def create(conn)
        path = path_for(conn) or return nil
        link = shell.CreateShortcut(win(path))
        link.TargetPath = win(rubyw)
        link.Arguments = %("#{win(LAUNCHER)}" #{MARKER} "#{name_of(conn).delete('"')}")
        link.WorkingDirectory = win(ROOT)
        link.IconLocation = "#{win(ICON)},0"
        link.Description = "TN3270: #{Config.connect_string(conn)}"
        link.Save
        path
      rescue StandardError
        nil
      end

      # Removes a connection's shortcut, but only one this app made.
      def remove(conn)
        path = path_for(conn)
        return nil unless path && File.exist?(path)
        return nil unless shell.CreateShortcut(win(path)).Arguments.to_s.include?(MARKER)

        File.delete(path)
        path
      rescue StandardError
        nil
      end

      def path_for(conn)
        dir = desktop or return nil
        file = name_of(conn).gsub(/[<>:"\/\\|?*\x00-\x1f]/, "_").strip.sub(/\.+\z/, "")
        return nil if file.empty?

        File.join(dir, "#{file}.lnk")
      end

      def name_of(conn)
        name = conn["name"].to_s.strip
        name.empty? ? Config.connect_string(conn) : name
      end

      # The real Desktop folder, even when OneDrive has moved it.
      def desktop
        dir = shell&.SpecialFolders("Desktop").to_s.tr("\\", "/")
        dir.empty? ? nil : dir
      rescue StandardError
        nil
      end

      # rubyw.exe runs without a console window; fall back to ruby.exe.
      def rubyw
        bin = RbConfig::CONFIG["bindir"]
        w = File.join(bin, "rubyw.exe")
        File.exist?(w) ? w : File.join(bin, "ruby.exe")
      end

      def shell
        return @shell if defined?(@shell)

        @shell = nil
        return nil unless Config::WINDOWS

        require "win32ole"
        @shell = WIN32OLE.new("WScript.Shell")
      rescue LoadError, StandardError
        @shell = nil
      end

      def win(path) = path.tr("/", "\\")
    end
  end
end
