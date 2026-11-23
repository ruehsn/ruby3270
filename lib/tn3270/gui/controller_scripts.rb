# frozen_string_literal: true

require_relative "startup_script"

module Tn3270
  module Gui
    # Scripts a Controller runs against its session, each in its own process
    # so the window stays usable: the connection's startup script, and ones
    # picked from a script folder. Each line a script prints, or its error,
    # shows in the status bar; they all end when the tab disconnects,
    # reconnects or closes.
    module ControllerScripts
      # Runs a script from a script folder against this session.
      def run_script(path, name)
        enqueue do
          if !connected?
            @message = "Connect first, then run \"#{name}\""
          elsif !@attach_port
            @message = "\"#{name}\" not run: the session has no script port yet. Reconnect to open one"
          else
            @scripts = (@scripts || []).select(&:alive?)
            run = launch_script(path, @last_target || {}, "Running #{name}...") do |error|
              error.sub(StartupScript::FAILED, "#{name} failed").sub("Startup script", name)
            end
            @scripts << run if run
          end
          notify
        end
      end

      # True while this tab's startup script is still running.
      def startup_script_running? = @startup_script&.alive? || false

      # True while any script this tab started (startup or script folder) runs.
      def scripts_running? = startup_script_running? || (@scripts || []).any?(&:alive?)

      # Stop Script: ends the scripts this tab started, and what they started.
      def stop_scripts
        enqueue do
          if scripts_running?
            stop_startup_script
            @message = "Script stopped"
          end
          notify
        end
      end

      private

      # Starts the startup script once the connection is up (checked on every poll).
      def run_startup_script
        return unless @script_conn && connected?

        conn = @script_conn
        @script_conn = nil
        path = StartupScript.path_for(conn)
        unless @attach_port
          @message = "Startup script not run: no free script port from #{@config['script_port']}"
          return notify
        end
        @startup_script = launch_script(path, conn, "Running startup script #{File.basename(path)}...")
      end

      # Starts a script with `running` in the status bar until it prints
      # something. The block, if given, rewords its error message.
      def launch_script(path, conn, running, &reword)
        @message = running
        notify
        on_status = lambda do |text|
          @message = text
          notify
        end
        run = nil
        on_exit = lambda do |error|
          error = nil if run&.stopped? # Stop Script: "Script stopped" stays
          error = reword.call(error) if error && reword
          @message = error || (@message == running ? nil : @message) # a quiet script leaves no message
          notify
        end
        run = StartupScript.start(path, conn, @attach_port, on_status: on_status, on_exit: on_exit)
      end

      def stop_startup_script
        StartupScript.stop(@startup_script)
        @startup_script = nil
        (@scripts || []).each { |s| StartupScript.stop(s) } # ones run from the snippet list
        @scripts = []
      end
    end
  end
end
