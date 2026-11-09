# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require_relative "../process_job"

module Tn3270
  module Gui
    # A connection's startup script: a file run once each time that
    # connection comes up. It runs in its own process, so the window stays
    # free while it works, and drives the tab's session through the tab's
    # script port (the same one Tn3270::Session.attach uses).
    #
    # Any kind of file works: .rb runs with the helpers below, .ps1 / .bat /
    # .cmd / .py / .vbs / .js with their usual interpreter, anything else is
    # started as is. Every script gets these environment variables, so one
    # script shared by several emulators can tell who started it:
    #
    #   TN3270_EMULATOR      "ruby3270"
    #   RUBY3270_VERSION     e.g. "0.1.0"
    #   TN3270_SESSION       the session's name (the saved connection's name)
    #   TN3270_HOST, TN3270_HOST_PORT, TN3270_LU, TN3270_TLS ("1"/"0"),
    #   TN3270_ROWS, TN3270_COLS          what the session is connected to
    #   TN3270_SCRIPT_HOST, TN3270_SCRIPT_PORT
    #                        where to attach: 127.0.0.1 and this tab's port
    #   RUBY3270_LIB         this app's lib folder (for require "tn3270")
    #   RUBY3270_CONNECTION  the saved connection as JSON
    #
    # Each line the script prints shows in the status bar. A Ruby script runs
    # already attached, with the session methods available directly:
    #
    #   wait_for_text("USER ID")
    #   fill("USER ID", "USER01")
    #   fill("PASSWORD", ENV["TSO_PW"])
    #   enter
    #   status "Logged on"            # shows in the status bar
    #
    # `connection` is the saved connection (a Hash: "name", "host", ...),
    # `session` the attached session, `emulator` "ruby3270".
    class StartupScript
      LIB = File.expand_path("../..", __dir__)
      RUNNER = File.expand_path("startup_runner.rb", __dir__)
      FAILED = "Startup script failed"

      # What a Ruby script's `self` is (in the script's own process).
      class Context
        attr_reader :session, :connection

        def initialize(session, connection)
          @session = session
          @connection = connection
        end

        def emulator = ENV.fetch("TN3270_EMULATOR", "ruby3270")
        def session_name = ENV.fetch("TN3270_SESSION", connection["name"].to_s)

        def status(text)
          $stdout.puts(text.to_s.lines.first.to_s.chomp)
          $stdout.flush
        end

        def method_missing(name, ...)
          @session.respond_to?(name) ? @session.public_send(name, ...) : super
        end

        def respond_to_missing?(name, include_private = false) = @session.respond_to?(name) || super

        # Runs the file; on an error, prints one line for the status bar to
        # stderr and returns false.
        def self.run(path, session, connection)
          new(session, connection).instance_eval(File.read(path, encoding: "UTF-8"), path, 1)
          true
        rescue StandardError, ScriptError => e
          where = e.backtrace_locations&.find { |l| l.path == path }
          warn "#{FAILED}#{where ? " (line #{where.lineno})" : ''}: #{e.message.lines.first.to_s.chomp}"
          false
        end
      end

      def self.path_for(conn)
        path = conn && conn["script"].to_s.strip
        path.nil? || path.empty? ? nil : File.expand_path(path)
      end

      def self.env(conn, port)
        {
          "TN3270_EMULATOR" => "ruby3270",
          "RUBY3270_VERSION" => (defined?(Tn3270::VERSION) ? Tn3270::VERSION : ""),
          "TN3270_SESSION" => conn["name"].to_s,
          "TN3270_HOST" => conn["host"].to_s,
          "TN3270_HOST_PORT" => conn["port"].to_s,
          "TN3270_LU" => conn["lu"].to_s,
          "TN3270_TLS" => conn["tls"] ? "1" : "0",
          "TN3270_ROWS" => conn["rows"].to_s,
          "TN3270_COLS" => conn["cols"].to_s,
          "TN3270_SCRIPT_HOST" => "127.0.0.1",
          "TN3270_SCRIPT_PORT" => port.to_s,
          "RUBY3270_LIB" => LIB,
          "RUBY3270_CONNECTION" => JSON.generate(conn.reject { |k, _| k == "password" })
        }
      end

      # The command line that runs the file.
      def self.command(path)
        case File.extname(path).downcase
        when ".rb", ".rbw" then [ruby_without_console, "-I", LIB, RUNNER, path]
        when ".ps1" then ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path]
        when ".bat", ".cmd" then ["cmd.exe", "/c", path]
        when ".py" then ["python", path]
        when ".vbs", ".js" then ["cscript.exe", "//nologo", path]
        else [path]
        end
      end

      # Windows: rubyw.exe, which never opens a console window.
      def self.ruby_without_console
        rubyw = File.join(RbConfig::CONFIG["bindir"], "rubyw.exe")
        ProcessJob::WINDOWS && File.file?(rubyw) ? rubyw : RbConfig.ruby
      end

      # A started script: still running? and stop.
      Running = Struct.new(:wait, :job) do
        def alive? = wait.alive?
        def pid = wait.pid
        def stop = job.stop
      end

      # Starts the script in its own process and returns at once. Lines it
      # prints go to on_status; when it ends, on_exit gets nil or an error
      # message for the status bar.
      def self.start(path, conn, port, on_status:, on_exit:)
        unless File.file?(path)
          on_exit.call("Startup script not found: #{path}")
          return nil
        end

        opts = { chdir: File.dirname(path) }
        opts[:pgroup] = true unless ProcessJob::WINDOWS # so stop reaches what it starts
        stdin, stdout, stderr, wait = Open3.popen3(env(conn, port), *command(path), **opts)
        stdin.close
        job = ProcessJob.new(wait.pid) # ends with this app, whatever happens
        errors = Thread.new { stderr.read.to_s.encode("UTF-8", invalid: :replace, undef: :replace) }
        Thread.new do
          stdout.each_line do |line|
            text = line.encode("UTF-8", invalid: :replace, undef: :replace).strip
            on_status.call(text) unless text.empty?
          end
          status = wait.value
          job.release
          on_exit.call(status.success? ? nil : failure(errors.value, status))
        rescue IOError, SystemCallError
          on_exit.call(nil)
        end
        Running.new(wait, job)
      rescue SystemCallError => e
        on_exit.call("#{FAILED}: couldn't start it (#{e.message.sub(/ - .*/, '')})")
        nil
      end

      def self.failure(stderr, status)
        line = stderr.lines.map(&:strip).reject(&:empty?)
        own = line.reverse.find { |l| l.start_with?(FAILED) }
        own || "#{FAILED} (exit #{status.exitstatus})#{": #{line.last}" if line.any?}"
      end

      # Stops a script and everything it started (its session closed or
      # reconnected).
      def self.stop(running)
        running&.stop
      end
    end
  end
end
