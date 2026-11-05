# frozen_string_literal: true

require_relative "engine"
require_relative "screen"

module Tn3270
  # The Ruby API. The GUI uses this, and so can your own scripts:
  #
  #   Tn3270::Session.open("localhost:3270") do |s|
  #     s.wait_for_text("USER ID")
  #     s.fill("USER ID", "USER01")
  #     s.press(:enter)
  #     puts s.screen.text
  #   end
  class Session
    KEYS = %i[enter clear tab backtab home newline reset erase_eof erase_input
              backspace delete up down left right insert attn sysreq].freeze

    ACTIONS = {
      enter: "Enter", clear: "Clear", tab: "Tab", backtab: "BackTab", home: "Home",
      newline: "Newline", reset: "Reset", erase_eof: "EraseEOF", erase_input: "EraseInput",
      backspace: "BackSpace", delete: "Delete", up: "Up", down: "Down", left: "Left",
      right: "Right", insert: "ToggleInsert", attn: "Attn", sysreq: "SysReq"
    }.freeze

    attr_reader :engine

    def self.open(host = nil, **opts)
      session = new(**opts)
      session.connect(host) if host
      return session unless block_given?

      begin
        yield session
      ensure
        session.close
      end
    end

    # rows/cols: screen size to offer the host (default 62x160).
    # timeout:   default seconds for waits.
    def initialize(rows: 62, cols: 160, timeout: 10, **engine_opts)
      @timeout = timeout
      @engine = Engine.new(rows: rows, cols: cols, **engine_opts)
    end

    # ---- connection ----------------------------------------------------------

    # "host", "host:port", or "L:host:port" for TLS.
    def connect(host, wait: true)
      @engine.run("Connect(#{host})")
      wait_for_input if wait
      self
    end

    def disconnect = tap { @engine.run("Disconnect()") }
    def close = @engine.close
    def connected? = status&.connected?
    def status = @engine.last_status || refresh_status

    def refresh_status
      @engine.run("Query(Cursor1)")
      @engine.last_status
    end

    # ---- reading the screen --------------------------------------------------

    # Fresh snapshot of the whole screen (characters, colors, fields).
    def screen
      lines = @engine.run("ReadBuffer(Ascii)")
      Screen.from_buffer(lines, @engine.last_status)
    end

    def text = screen.text
    def include?(needle) = screen.include?(needle)
    def fields = screen.fields
    def input_fields = screen.input_fields
    def field_at(row, col) = screen.field_at(row, col)

    # Text at a position (0-based row/col).
    def read(row, col, length)
      @engine.run("Ascii(#{row},#{col},#{length})").join
    end

    # ---- typing --------------------------------------------------------------

    def type(text) = tap { @engine.run("String(#{Engine.quote(text)})") }

    def move_to(row, col) = tap { @engine.run("MoveCursor(#{row},#{col})") }

    # Put text in a field. `where` is a label on the screen ("USER ID"),
    # a [row, col] pair, or a Field.
    def fill(where, text, clear: true)
      field = case where
              when Field then where
              when Array then screen.field_at(*where)
              else screen.field_after(where.to_s)
              end
      raise Error, "no input field found for #{where.inspect}" unless field

      move_to(field.row, field.col)
      @engine.run("EraseEOF") if clear
      type(text)
    end

    # ---- AID and editing keys ------------------------------------------------

    # press(:enter), press(:pf3), press(:pa1), press(:clear), press(:tab)...
    def press(key, wait: true)
      name = key.to_s.downcase
      action = case name
               when /\Apf(\d+)\z/ then "PF(#{Regexp.last_match(1)})"
               when /\Apa(\d)\z/ then "PA(#{Regexp.last_match(1)})"
               else ACTIONS.fetch(name.to_sym) { raise ArgumentError, "unknown key #{key.inspect}" }
               end
      @engine.run(action)
      wait_for_host if wait && aid?(name)
      self
    end

    def pf(n, **kw) = press(:"pf#{n}", **kw)
    def pa(n, **kw) = press(:"pa#{n}", **kw)
    def enter(**kw) = press(:enter, **kw)

    # ---- waiting -------------------------------------------------------------

    def wait_for_input(timeout: @timeout)
      @engine.run("Wait(#{timeout},InputField)")
      self
    rescue ActionError => e
      raise TimeoutError, e.message
    end

    # Wait until the host has answered an AID key and the keyboard unlocks.
    def wait_for_host(timeout: @timeout)
      @engine.run("Wait(#{timeout},Unlock)")
      self
    rescue ActionError => e
      raise TimeoutError, e.message
    end

    def wait_for_text(needle, timeout: @timeout)
      deadline = Time.now + timeout
      loop do
        return self if needle.is_a?(Regexp) ? text.match?(needle) : include?(needle)
        raise TimeoutError, "timed out waiting for #{needle.inspect}" if Time.now > deadline

        sleep 0.1
      end
    end

    # Run any s3270 action directly, e.g. raw("PrintText(file,screen.txt)").
    def raw(action) = @engine.run(action)

    private

    def aid?(name) = name.match?(/\A(pf\d+|pa\d|enter|clear|attn|sysreq)\z/)
  end
end
