# frozen_string_literal: true

require "json"
require "socket"
require "securerandom"

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
      FIELDS = %w[session host].freeze

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
          begin
            request = client.wait_readable(2) && self.class.parse(client.gets("\n", MAX_LINE), @token)
            client.write(request ? "ok\n" : "no\n")
            @requests << request if request
          rescue StandardError
            nil
          ensure
            client.close
          end
        end
      rescue IOError, SystemCallError
        nil # closed
      end
    end
  end
end
