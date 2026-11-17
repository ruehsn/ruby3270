# frozen_string_literal: true

require "json"
require "socket"
require "securerandom"
require_relative "../engine" # Tn3270::Error

module Tn3270
  module Gui
    # Keeps the app to one running copy per user. The first copy listens on a
    # random local port and writes the port and a secret token to a file in
    # the user's home folder. A later launch (a desktop shortcut, say) sends
    # its session there and exits, and the running copy opens it in a tab.
    #
    # One process is also what lets a tab be dragged from any window into any
    # other: a tab's connection can't move between processes.
    #
    # The token is only readable by the user, so other users on the same
    # computer (a terminal server) can't open sessions in someone else's app.
    class Instance
      FILE = File.join(Dir.home, ".ruby3270.instance")
      MAX_LINE = 4096
      REPLY_WAIT = 14 # seconds the app has to open a tab and say which port it has
      FIELDS = %w[session host tab want].freeze # tab: find an open tab by name; want: "port" asks for its script port

      # Asks a running copy to open `request` ({"session" => name} or
      # {"host" => "host:port"}, or {} for a new window). True if it did.
      def self.forward(request, path: FILE, timeout: 1.5)
        info = JSON.parse(File.read(path))
        port = info["port"].to_i
        token = info["token"].to_s
        return false unless port.positive? && !token.empty?

        Socket.tcp("127.0.0.1", port, connect_timeout: timeout) do |sock|
          sock.write("#{JSON.generate('token' => token, 'open' => request)}\n")
          sock.wait_readable(timeout) && sock.gets.to_s.strip == "ok"
        end
      rescue StandardError
        false
      end

      # Asks a running copy to open a session in a tab and returns that tab's
      # script port (for Session.attach), or nil if nothing is running.
      # request: {"host" => "host:port"} or {"session" => "saved name"}.
      # Raises Tn3270::Error if the app answers but the tab has no port (scripts
      # aren't allowed to attach, or none was free) or doesn't answer in time.
      def self.open_tab(request, path: FILE, timeout: 15)
        ask_port(request, path: path, timeout: timeout,
                          refused: "ruby3270 opened the session but scripts can't attach to it " \
                                   "(Session > Allow Scripts to Attach is off, or no port was free)")
      end

      # The script port of the open tab named `name` (as its tab shows it,
      # renamed or not; any case), or nil if ruby3270 isn't running. Raises
      # Tn3270::Error if no tab has that name or it has no script port.
      def self.find_tab(name, path: FILE, timeout: 5)
        ask_port({ "tab" => name.to_s }, path: path, timeout: timeout,
                                         refused: "No tab named \"#{name}\" in ruby3270 " \
                                                  "(or scripts can't attach to it)")
      end

      def self.ask_port(request, path:, timeout:, refused:)
        info = JSON.parse(File.read(path))
        port = info["port"].to_i
        token = info["token"].to_s
        return nil unless port.positive? && !token.empty?

        reply = Socket.tcp("127.0.0.1", port, connect_timeout: 1.5) do |sock|
          sock.write("#{JSON.generate('token' => token, 'open' => request.merge('want' => 'port'))}\n")
          sock.wait_readable(timeout) ? sock.gets.to_s.strip : ""
        end
        raise Tn3270::Error, "ruby3270 didn't answer in #{timeout}s" if reply.empty?
        return Integer(reply.split.last) if reply.start_with?("ok ") && reply.split.last.match?(/\A\d+\z/)

        raise Tn3270::Error, refused
      rescue Errno::ENOENT, Errno::ECONNREFUSED, JSON::ParserError, SocketError, Errno::ETIMEDOUT
        nil
      end

      # The request in a line from another copy, or nil if the token is wrong
      # or the line isn't one. Only known fields, as short strings, are kept.
      def self.parse(line, token)
        data = JSON.parse(line.to_s)
        return nil unless data.is_a?(Hash) && data["token"].is_a?(String) && data["open"].is_a?(Hash)
        return nil unless data["token"].bytesize == token.bytesize && secure_equal?(data["token"], token)

        data["open"].slice(*FIELDS).select { |_, v| v.is_a?(String) && !v.strip.empty? && v.size <= 200 }
      rescue JSON::ParserError
        nil
      end

      def self.secure_equal?(a, b)
        a.bytes.zip(b.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
      end

      def initialize(path: FILE)
        @path = path
        @token = SecureRandom.hex(16)
        @requests = Queue.new
        @server = TCPServer.new("127.0.0.1", 0)
        File.write(path, JSON.generate("port" => @server.addr[1], "token" => @token, "pid" => Process.pid))
        @thread = Thread.new { serve }
      rescue StandardError
        @server&.close
        @server = nil
      end

      def listening? = !@server.nil?

      # Requests that came in since the last call (never blocks).
      def requests
        list = []
        list << @requests.pop until @requests.empty?
        list
      end

      def close
        @server&.close
        @thread&.kill
        File.delete(@path) if File.exist?(@path) && File.read(@path).include?(@token)
      rescue StandardError
        nil
      end

      private

      def serve
        loop do
          client = @server.accept
          Thread.new { answer(client) } # one may wait for a tab, so none holds up the rest
        end
      rescue IOError, SystemCallError
        nil # closed
      end

      # Reads one request. A plain one is answered "ok" at once. One with
      # want=port is handed over with a reply queue, and answered
      # "ok <port>" when the app has the tab (or "no" if it has no port).
      def answer(client)
        request = client.wait_readable(2) && self.class.parse(client.gets("\n", MAX_LINE), @token)
        return client.write("no\n") unless request

        if request.delete("want") == "port"
          reply = Queue.new
          @requests << request.merge("reply" => reply)
          port = reply.pop(timeout: REPLY_WAIT)
          client.write(port ? "ok #{port}\n" : "no\n")
        else
          client.write("ok\n")
          @requests << request
        end
      rescue StandardError
        nil
      ensure
        client.close
      end
    end
  end
end
