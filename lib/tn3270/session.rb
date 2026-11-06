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

    # Attaches to a session that is already open, such as the one in the
    # ruby3270 window (Session > Allow Scripts to Attach). The script works
    # on the live screen; `close` lets go of it and leaves the session running.
    #
    #   Tn3270::Session.attach do |s|
    #     puts s.text
    #   end
    def self.attach(port: 3271, host: "127.0.0.1", timeout: 10)
      session = new(engine: Engine.attach(port: port, host: host), timeout: timeout)
      return session unless block_given?

      begin
        yield session
      ensure
        session.close
      end
    end

    # rows/cols:   screen size to offer the host (default 62x160).
    # timeout:     default seconds for waits.
    # script_port: let other scripts attach to this session (Session.attach).
    # engine:      an Engine to use instead of starting one.
    def initialize(rows: 62, cols: 160, timeout: 10, engine: nil, **engine_opts)
      @timeout = timeout
      @engine = engine || Engine.new(rows: rows, cols: cols, **engine_opts)
    end

    # True for a session joined with Session.attach.
    def attached? = @engine.attached?

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

    # ---- everyday helpers ------------------------------------------------------
    # Small building blocks most scripts need. All waits take `timeout:`
    # (seconds) and raise TimeoutError when it runs out.

    # Waits until the block returns something truthy for the current screen,
    # and returns that value. The block gets a fresh Screen each time.
    #   s.wait_until { |scr| scr.row_text(0).include?("EDIT") }
    def wait_until(timeout: @timeout, every: 0.1, message: "the condition")
      deadline = Time.now + timeout
      loop do
        result = yield(screen)
        return result if result
        raise TimeoutError, "timed out waiting for #{message}" if Time.now > deadline

        sleep every
      end
    end

    # Waits until the text (or Regexp) is no longer on the screen, e.g. a
    # "PLEASE WAIT" message.
    def wait_for_text_gone(needle, timeout: @timeout)
      wait_until(timeout: timeout, message: "#{needle.inspect} to go away") do |scr|
        needle.is_a?(Regexp) ? !scr.text.match?(needle) : !scr.include?(needle)
      end
      self
    end

    # Waits until the screen is different from the one given (or from now).
    #   before = s.screen
    #   s.enter(wait: false)
    #   s.wait_for_change(before)
    def wait_for_change(before = screen, timeout: @timeout)
      old = before.is_a?(Screen) ? before.text : before.to_s
      wait_until(timeout: timeout, message: "the screen to change") { |scr| scr.text != old }
      self
    end

    # Presses a key, then waits for the host: for `text` to appear when given,
    # otherwise for the screen to change. Returns the session.
    #   s.press_and_wait(:enter, "READY")
    #   s.press_and_wait(:pf8)               # next page
    def press_and_wait(key, text = nil, timeout: @timeout)
      before = screen
      press(key, wait: false)
      text ? wait_for_text(text, timeout: timeout) : wait_for_change(before, timeout: timeout)
    end

    # Types into the field after a label, presses Enter and waits for `text`
    # (or for the screen to change). The usual "enter a command" step.
    #   s.submit("COMMAND ===>", "TSO LISTCAT", wait_for: "READY")
    #   s.submit("OPTION", "3.4")
    def submit(where, value, key: :enter, wait_for: nil, timeout: @timeout)
      fill(where, value)
      press_and_wait(key, wait_for, timeout: timeout)
    end

    # Fills several fields at once: { label or [row, col] => text }.
    #   s.fill_form("USER ID" => "USER01", "PASSWORD" => ENV["PW"])
    def fill_form(values)
      values.each { |where, text| fill(where, text.to_s) }
      self
    end

    # The text in the input field after a label, trimmed (nil if no such field).
    #   s.value("USER ID")   # => "USER01"
    def value(label)
      screen.field_after(label.to_s)&.value&.strip
    end

    # One screen row as text (0-based), trailing blanks removed.
    def line(row) = screen.row_text(row).rstrip

    # Every row as an array of strings, trailing blanks removed.
    def lines = screen.text.lines(chomp: true).map(&:rstrip)

    # Where text appears: [[row, col, length], ...]. Rows and columns are 0-based.
    def find(term, match_case: false) = screen.find(term, match_case: match_case)

    # Whether text (or a Regexp) is on the screen now.
    def on_screen?(needle) = needle.is_a?(Regexp) ? text.match?(needle) : include?(needle)

    # The cursor position: [row, col], 0-based.
    def cursor
      st = refresh_status
      [st.cursor_row, st.cursor_col]
    end

    def keyboard_locked? = refresh_status&.keyboard_locked? || false

    # Writes the screen text to a file (and returns the text).
    def save_screen(path)
      text.tap { |t| File.write(path, "#{t}\n") }
    end

    # Pages with `key` (PF8 by default) until `needle` shows up, for lists
    # that run over several screens. Gives up after `max_pages`, or when a
    # page looks the same as the one before (the end of the list).
    # Returns true if found.
    #   s.page_until("MY.DATASET")
    def page_until(needle, key: :pf8, max_pages: 50, timeout: @timeout)
      max_pages.times do
        return true if on_screen?(needle)

        before = screen
        press(key, wait: false)
        wait_for_host(timeout: timeout)
        return on_screen?(needle) if screen.text == before.text
      end
      on_screen?(needle)
    end

    # Signs on with the usual two fields, then waits for `wait_for` (or for
    # the screen to change). Labels default to "USER ID" and "PASSWORD".
    #   s.logon("USER01", ENV["TSO_PW"], wait_for: "READY")
    def logon(user, password, user_label: "USER ID", password_label: "PASSWORD", wait_for: nil, timeout: @timeout)
      wait_for_text(user_label, timeout: timeout)
      fill(user_label, user)
      fill(password_label, password) if password
      press_and_wait(:enter, wait_for, timeout: timeout)
    end

    # Types a snippet at the cursor: text with {Enter}, {PF3}, {wait:READY},
    # {ask:...}, {date}... (see Tn3270::Snippet). Answers for {ask:...} come
    # from `answers`.
    #   s.type_snippet("=3.4{Enter}USER01.*{Enter}")
    #   s.type_snippet("SUBMIT '{ask:Data set}'{Enter}", answers: { "Data set" => "USER01.JCL(RUN)" })
    def type_snippet(text, answers: {}, wait_timeout: 30, **vars)
      Snippet.run(self, text, answers: answers, vars: vars, wait_timeout: wait_timeout)
    end

    private

    def aid?(name) = name.match?(/\A(pf\d+|pa\d|enter|clear|attn|sysreq)\z/)
  end
end
