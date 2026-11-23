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
    #
    # Scripts use the same line to talk to the person at the window
    # (Session#ask, #choose, #show, #notify): see `user_request`.
    class Instance
      FILE = File.join(Dir.home, ".ruby3270.instance")
      MAX_LINE = 4096
      MAX_UI_LINE = 300_000 # a script's request to the user (show can carry a long text)
      MAX_TEXT = 200_000
      UI_KINDS = %w[ask choose show notify].freeze
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

      # Sends a script's request to the person at the window (`ui`: a Hash
      # with "kind" ask / choose / show / notify, see parse_ui) and waits,
      # however long they take, for the answer: {"value" => ...},
      # {"cancel" => true}, {"stop" => true} or {"ok" => true}. Raises
      # Tn3270::Error if ruby3270 isn't running.
      def self.user_request(ui, path: FILE)
        info = JSON.parse(File.read(path))
        port = info["port"].to_i
        token = info["token"].to_s
        raise Tn3270::Error, "ruby3270 isn't running" unless port.positive? && !token.empty?

        Socket.tcp("127.0.0.1", port, connect_timeout: 1.5) do |sock|
          sock.write("#{JSON.generate('token' => token, 'ui' => ui)}\n")
          reply = JSON.parse(sock.gets.to_s)
          reply.is_a?(Hash) ? reply : raise(Tn3270::Error, "ruby3270 didn't answer")
        end
      rescue Errno::ENOENT, Errno::ECONNREFUSED, SocketError, Errno::ETIMEDOUT
        raise Tn3270::Error, "ruby3270 isn't running (start it first; Config single_instance must be on)"
      rescue JSON::ParserError, IOError, SystemCallError
        raise Tn3270::Error, "ruby3270 didn't answer"
      end

      # The request in a line from another copy, or nil if the token is wrong
      # or the line isn't one. Only known fields, as short strings, are kept.
      def self.parse(line, token)
        data = JSON.parse(line.to_s)
        return nil unless data.is_a?(Hash) && token_ok?(data["token"], token) && data["open"].is_a?(Hash)

        data["open"].slice(*FIELDS).select { |_, v| v.is_a?(String) && !v.strip.empty? && v.size <= 200 }
      rescue JSON::ParserError
        nil
      end

      # A script's request to the user in a line, or nil (wrong token, not
      # one). Only known fields are kept, each cut to a sensible size.
      def self.parse_ui(line, token)
        data = JSON.parse(line.to_s)
        return nil unless data.is_a?(Hash) && token_ok?(data["token"], token) && data["ui"].is_a?(Hash)

        ui = data["ui"]
        return nil unless UI_KINDS.include?(ui["kind"])

        text = ->(key, max) { ui[key].is_a?(String) ? ui[key][0, max] : nil }
        options = ui["options"].is_a?(Array) ? ui["options"].grep(String).first(500).map { |o| o[0, 200] } : []
        { "kind" => ui["kind"], "title" => text.("title", 200), "prompt" => text.("prompt", 2000),
          "default" => text.("default", 2000), "text" => text.("text", MAX_TEXT), "options" => options,
          "secret" => ui["secret"] == true, "wait" => ui["wait"] == true,
          "port" => (ui["port"] if ui["port"].is_a?(Integer)) }.compact
      rescue JSON::ParserError
        nil
      end

      def self.token_ok?(given, token)
        given.is_a?(String) && given.bytesize == token.bytesize && secure_equal?(given, token)
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
        line = client.wait_readable(2) && client.gets("\n", MAX_UI_LINE)
        ui = self.class.parse_ui(line, @token)
        return answer_user_request(client, ui) if ui

        request = line && line.bytesize <= MAX_LINE && self.class.parse(line, @token)
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

      # A script asks the user something. The app gets {"ui", "id", "reply"};
      # the answer can take as long as the person likes. If the script goes
      # away first (stopped, killed), the app hears {"ui_gone" => id} so it
      # can close the question.
      def answer_user_request(client, ui)
        reply = Queue.new
        id = SecureRandom.hex(6)
        @requests << { "ui" => ui, "id" => id, "reply" => reply }
        loop do
          answer = reply.pop(timeout: 0.5)
          return client.write("#{JSON.generate(answer)}\n") if answer
          next unless gone?(client)

          @requests << { "ui_gone" => id }
          return
        end
      end

      # True once the other end has closed the connection.
      def gone?(client)
        return false unless client.wait_readable(0)

        client.read_nonblock(1, exception: false).nil?
      rescue IOError, SystemCallError
        true
      end
    end
  end
end
