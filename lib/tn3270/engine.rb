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

    # Starts an engine.
    #   script_port: also let other programs drive this engine over TCP on
    #                127.0.0.1:script_port (see Engine.attach). This engine
    #                then talks to it over that port too.
    def initialize(exe: nil, rows: 62, cols: 160, model: nil, extra_args: [], script_port: nil)
      exe = self.class.default_exe if exe.nil? || exe.to_s.strip.empty?
      @rows = rows
      @cols = cols
      @mutex = Mutex.new
      @script_port = script_port
      utf8 = DEFAULT_EXE.end_with?(".exe") ? ["-localcp", "65001"] : ["-utf8"]
      model ||= self.class.model_for(rows, cols)
      args = [exe, "-model", model, *utf8]
      args += ["-oversize", "#{cols}x#{rows}"] unless MODELS.key?([rows, cols])
      args += extra_args
      self.class.hidden_console
      if script_port
        start_with_port(args, script_port)
      else
        @stdin, @stdout, @wait = Open3.popen2(*args, err: File::NULL)
        @stdout.set_encoding("UTF-8")
      end
    rescue Errno::ENOENT
      raise Error, "Could not start '#{exe}'. Install the x3270 suite (wc3270 on Windows includes ws3270.exe) " \
                   "or set TN3270_ENGINE to its full path."
    end

    # Windows: when this program has no console (rubyw.exe, as desktop
    # shortcuts use), starting the engine would open a console window for it,
    # and with Windows Terminal as the default terminal the engine's output can
    # end up in that window instead of reaching us. So give this process a
    # console with no window first; the engine shares it.
    ALLOC_CONSOLE_MODE_NO_WINDOW = 2
    SW_HIDE = 0

    def self.hidden_console
      return unless DEFAULT_EXE.end_with?(".exe") && !@console_ready

      @console_ready = true
      require "fiddle"
      kernel = Fiddle.dlopen("kernel32")
      p = Fiddle::TYPE_VOIDP
      return unless Fiddle::Function.new(kernel["GetConsoleWindow"], [], p).call.null?

      begin
        # Windows 11 24H2 and later: a console that never has a window.
        alloc = Fiddle::Function.new(kernel["AllocConsoleWithOptions"], [p, p], Fiddle::TYPE_INT)
        options = [ALLOC_CONSOLE_MODE_NO_WINDOW, 0, 0].pack("LLS")
        alloc.call(Fiddle::Pointer[options], Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE))
      rescue Fiddle::DLError
        # Older Windows: make one and hide it straight away.
        Fiddle::Function.new(kernel["AllocConsole"], [], Fiddle::TYPE_INT).call
        window = Fiddle::Function.new(kernel["GetConsoleWindow"], [], p).call
        user32 = Fiddle.dlopen("user32")
        Fiddle::Function.new(user32["ShowWindow"], [p, Fiddle::TYPE_INT], Fiddle::TYPE_INT).call(window, SW_HIDE) unless window.null?
      end
    rescue StandardError
      nil # worst case: the old behaviour, a visible console window
    end

    # Connects to an engine someone else started with a script port, such as
    # the ruby3270 window with "Allow Scripts to Attach" on. Closing this
    # engine only drops the connection; the session carries on.
    def self.attach(port: 3271, host: "127.0.0.1")
      engine = allocate
      engine.send(:open_socket, host, port)
      engine
    end

    # Whether something already has 127.0.0.1:port (or the port can't be
    # used). Tried by binding to it, which answers at once; connecting to a
    # free port takes Windows about 2 seconds to refuse.
    def self.port_in_use?(port)
      require "socket"
      probe = Socket.new(:INET, :STREAM) # no SO_REUSEADDR: any owner makes bind fail
      probe.bind(Addrinfo.tcp("127.0.0.1", port))
      false
    rescue SystemCallError, SocketError
      true
    ensure
      probe&.close
    end

    # The first port from `start` that nothing is listening on (looking at
    # `tries` ports), or nil. Lets several windows each have their own port.
    def self.free_port(start, tries: 10)
      (start...(start + tries)).find { |port| !port_in_use?(port) }
    end

    attr_reader :script_port

    # True when this engine is someone else's (Engine.attach).
    def attached? = @attached || false

    # Runs an action like "Enter" or "PF(3)" and returns its data lines.
    def run(action)
      @mutex.synchronize do
        raise Error, "engine is not running" unless alive?

        @stdin.puts(action)
        @stdin.flush
        data = []
        loop do
          line = @stdout.gets or raise Error, attached? ? "the session closed the connection" : "engine exited"
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
    rescue IOError, SystemCallError => e
      # The pipe or socket broke: the engine was stopped (see #kill) or crashed.
      raise Error, attached? ? "the session closed the connection" : "the engine stopped (#{e.class.name.split('::').last})"
    end

    # Stops the engine at once, even in the middle of an action (which then
    # raises Error). For an attached engine, just drops the connection.
    def kill
      @killed = true # counts as stopped from now on, even before the process has gone
      return close_socket if attached?

      close_socket
      Process.kill("KILL", @wait.pid) if @wait&.alive?
    rescue SystemCallError
      nil
    end

    def alive?
      return false if @killed
      return !@stdin.closed? if attached?
      return false if @socket&.closed?

      @wait&.alive? || false
    end

    def close
      return close_socket if attached?
      return unless alive?

      # Another thread is stuck in an action (a connect that never finishes):
      # don't queue behind it, stop the engine.
      return kill if @mutex.locked? && !@mutex.owned?

      if @script_port
        # Over a script port, Quit() only ends this connection: stop the process.
        close_socket
        Process.kill("KILL", @wait.pid)
        @wait.join(2)
        return
      end
      begin
        run("Quit()")
      rescue Error, IOError
        nil
      end
      @stdin.close unless @stdin.closed?
      @wait.join(2) || Process.kill("TERM", @wait.pid)
    rescue SystemCallError, IOError
      nil
    end

    private

    # Starts the engine listening on a local port, then connects to it.
    def start_with_port(args, port)
      # Never talk to an engine we didn't start: if something already answers
      # on this port (another ruby3270 window), a connect would reach that one.
      raise Error, "port #{port} is already in use" if self.class.port_in_use?(port)

      pid = Process.spawn(*args, "-scriptport", "127.0.0.1:#{port}", in: File::NULL, out: File::NULL, err: File::NULL)
      @wait = Process.detach(pid)
      deadline = Time.now + 10
      # Wait for the engine to take the port before connecting (see port_in_use?).
      sleep 0.02 while @wait.alive? && Time.now < deadline && !self.class.port_in_use?(port)
      begin
        open_socket("127.0.0.1", port, attached: false)
      rescue Error
        retry if @wait.alive? && Time.now < deadline && sleep(0.05)
        Process.kill("KILL", pid) if @wait.alive?
        raise Error, "the engine could not listen on port #{port} (is another session using it?)"
      end
      # If our engine couldn't take the port and exited, the connection above
      # went to somebody else's engine (the port was taken a moment ago).
      sleep 0.15
      return if @wait.alive?

      close_socket
      raise Error, "port #{port} is already in use"
    end

    def open_socket(host, port, attached: true)
      require "socket"
      @mutex ||= Mutex.new
      @attached = attached
      @socket = TCPSocket.new(host, port)
      @socket.set_encoding("UTF-8")
      @stdin = @stdout = @socket
      return unless attached

      run("Query(Cursor1)") # learns the screen size
      @rows = @last_status&.rows
      @cols = @last_status&.cols
    rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH, SocketError => e
      raise Error, "nothing to attach to at #{host}:#{port} (#{e.message.sub(/ - .*/, '')}). " \
                   "In ruby3270, turn on Session > Allow Scripts to Attach."
    end

    def close_socket
      @socket.close unless @socket.nil? || @socket.closed?
    end

    public

    # Quote a string for an action argument: String("...").
    def self.quote(text)
      %("#{text.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}")
    end
  end
end
