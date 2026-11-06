# frozen_string_literal: true

module Tn3270
  module Gui
    # A connection's startup script: a Ruby file run once each time that
    # connection comes up. It runs on the worker thread against the live
    # session, so keys typed meanwhile wait until it ends. Session methods
    # can be called directly or on `session`:
    #
    #   wait_for_text("USER ID")
    #   fill("USER ID", "USER01")
    #   fill("PASSWORD", ENV["TSO_PW"])
    #   enter
    #   session.wait_for_text("READY")
    #   status "Logged on"            # shows in the status bar
    #
    # `connection` is the saved connection (a Hash: "name", "host", ...).
    class StartupScript
      # Wraps the session so the window redraws after every call.
      class SessionProxy
        def initialize(session, after)
          @session = session
          @after = after
        end

        def method_missing(name, ...)
          return super unless @session.respond_to?(name)

          result = @session.public_send(name, ...)
          @after.call
          result.equal?(@session) ? self : result # keep chains like fill(...).enter going through here
        end

        def respond_to_missing?(name, include_private = false) = @session.respond_to?(name) || super
      end

      # What the script's `self` is.
      class Context
        attr_reader :session, :connection

        def initialize(session, connection, on_status)
          @session = session
          @connection = connection
          @on_status = on_status
        end

        def status(text) = @on_status.call(text.to_s)

        def method_missing(name, ...)
          @session.respond_to?(name) ? @session.public_send(name, ...) : super
        end

        def respond_to_missing?(name, include_private = false) = @session.respond_to?(name) || super
      end

      def self.path_for(conn)
        path = conn && conn["script"].to_s.strip
        path.nil? || path.empty? ? nil : File.expand_path(path)
      end

      # Runs the file; returns nil, or an error message for the status bar.
      #   after:     called after each session call (redraws the window)
      #   on_status: called with the text a script passes to `status`
      def self.run(path, session, connection, after:, on_status:)
        return "Startup script not found: #{path}" unless File.file?(path)

        proxy = SessionProxy.new(session, after)
        Context.new(proxy, connection, on_status).instance_eval(File.read(path, encoding: "UTF-8"), path, 1)
        nil
      rescue StandardError, ScriptError => e
        where = e.backtrace_locations&.find { |l| l.path == path }
        "Startup script failed#{where ? " (line #{where.lineno})" : ''}: #{e.message}"
      end
    end
  end
end
