# frozen_string_literal: true

require "open3"
require "rbconfig"

module Tn3270
  class Error < StandardError; end
  class ActionError < Error; end
  class TimeoutError < Error; end

  # Status line s3270 prints after every action.
  Status = Struct.new(:keyboard, :formatted, :protected_field, :connection, :mode,
                      :model, :rows, :cols, :cursor_row, :cursor_col, :raw, keyword_init: true) do
    def self.parse(line)
      f = line.split
      new(keyboard: f[0], formatted: f[1] == "F", protected_field: f[2] == "P",
          connection: f[3], mode: f[4], model: f[5], rows: f[6].to_i, cols: f[7].to_i,
          cursor_row: f[8].to_i, cursor_col: f[9].to_i, raw: line)
    end

    def connected? = connection.to_s.start_with?("C")
    def host = connection.to_s[/\AC\((.*)\)\z/, 1]
    def keyboard_locked? = keyboard != "U"
    def error? = keyboard == "E"
  end

  # Runs one s3270 (ws3270.exe on Windows) process and sends it actions.
  # Every call is serialized with a mutex, so it is safe to share between
  # the GUI's poll thread and key handlers.
  class Engine
    DEFAULT_EXE = RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin/ ? "ws3270.exe" : "s3270"

    # Where the wc3270 installer puts ws3270.exe, tried when it isn't on PATH.
    INSTALL_DIRS = [ENV["ProgramFiles"], ENV["ProgramFiles(x86)"], ENV["ProgramW6432"]]
                   .compact.uniq.map { |d| File.join(d.tr("\\", "/"), "wc3270") }.freeze

    # TN3270_ENGINE, else the name on PATH, else a standard install folder.
    def self.default_exe
      env = ENV["TN3270_ENGINE"].to_s.strip
      return env unless env.empty?
      return DEFAULT_EXE if on_path?(DEFAULT_EXE)

      INSTALL_DIRS.map { |d| File.join(d, DEFAULT_EXE) }.find { |f| File.file?(f) } || DEFAULT_EXE
    end

    def self.on_path?(name)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |d| File.file?(File.join(d, name)) }
    end

    attr_reader :rows, :cols, :last_status

    # Standard 3279 models by screen size; anything else is model 2 plus -oversize.
    MODELS = { [24, 80] => 2, [32, 80] => 3, [43, 80] => 4, [27, 132] => 5 }.freeze

    def self.model_for(rows, cols) = "3279-#{MODELS.fetch([rows, cols], 2)}-E"

    def initialize(exe: nil, rows: 62, cols: 160, model: nil, extra_args: [])
      exe = self.class.default_exe if exe.nil? || exe.to_s.strip.empty?
      @rows = rows
      @cols = cols
      @mutex = Mutex.new
      utf8 = DEFAULT_EXE.end_with?(".exe") ? ["-localcp", "65001"] : ["-utf8"]
      model ||= self.class.model_for(rows, cols)
      args = [exe, "-model", model, *utf8]
      args += ["-oversize", "#{cols}x#{rows}"] unless MODELS.key?([rows, cols])
      args += extra_args
      @stdin, @stdout, @wait = Open3.popen2(*args, err: File::NULL)
      @stdout.set_encoding("UTF-8")
    rescue Errno::ENOENT
      raise Error, "Could not start '#{exe}'. Install the x3270 suite (wc3270 on Windows includes ws3270.exe) " \
                   "or set TN3270_ENGINE to its full path."
    end

    # Runs an action like "Enter" or "PF(3)" and returns its data lines.
    def run(action)
      @mutex.synchronize do
        raise Error, "engine is not running" unless alive?

        @stdin.puts(action)
        @stdin.flush
        data = []
        loop do
          line = @stdout.gets or raise Error, "engine exited"
          line = line.chomp
          if line.start_with?("data: ")
            data << line.delete_prefix("data: ")
          elsif line == "data:"
            data << ""
          elsif line == "ok"
            return data
          elsif line == "error"
            raise ActionError, "#{action}: #{data.join(' ').strip}"
          else
            @last_status = Status.parse(line)
          end
        end
      end
    end

    def alive? = @wait&.alive?

    def close
      return unless alive?

      begin
        run("Quit()")
      rescue Error, IOError
        nil
      end
      @stdin.close unless @stdin.closed?
      @wait.join(2) || Process.kill("TERM", @wait.pid)
    rescue Errno::ESRCH
      nil
    end

    # Quote a string for an action argument: String("...").
    def self.quote(text)
      %("#{text.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}")
    end
  end
end
