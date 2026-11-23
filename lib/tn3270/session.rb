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

    # Keys the host answers (they send the screen to it).
    AID = /\A(pf\d+|pa\d|enter|clear|attn|sysreq)\z/

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
    #
    # tab: attach to the tab with this name instead (as the tab shows it, so
    # a renamed tab goes by its new name; any case), wherever its port is:
    #
    #   Tn3270::Session.attach(tab: "Payroll") { |s| puts s.line(0) }
    def self.attach(port: 3271, host: "127.0.0.1", timeout: 10, tab: nil)
      port = port_of_tab(tab) if tab
      session = new(engine: Engine.attach(port: port, host: host), timeout: timeout)
      session.window_port = port # so questions to the user open over this tab
      return session unless block_given?

      begin
        yield session
      ensure
        session.close
      end
    end

    # The script port of the ruby3270 tab named `name`.
    def self.port_of_tab(name)
      require_relative "gui/instance"
      Gui::Instance.find_tab(name) or
        raise Error, "ruby3270 isn't running (start it first; Config single_instance must be on)"
    end

    # Opens a new tab in the running ruby3270 window, connects it, and
    # returns a session attached to it, so you watch the script work and the
    # tab stays open afterwards. Give a host ("host:port", ...) or the name of
    # a saved session. With wait: true (the default) it returns once the host
    # shows an input field.
    #
    #   Tn3270::Session.open_in_window("mvs.example.com:23") do |s|
    #     s.logon("USER01", ENV["TSO_PW"], wait_for: "READY")
    #   end   # lets go; the tab stays open
    #
    # Raises Tn3270::Error if ruby3270 isn't running (or single_instance is
    # off) or doesn't allow scripts to attach.
    def self.open_in_window(host = nil, session: nil, wait: true, timeout: 10, &block)
      raise ArgumentError, "give a host or a session name" unless host || session

      require_relative "gui/instance"
      request = { "host" => host, "session" => session }.compact
      port = Gui::Instance.open_tab(request, timeout: timeout + 5)
      raise Error, "ruby3270 isn't running (start it first; Config single_instance must be on)" unless port

      s = attach(port: port, timeout: timeout)
      begin
        if wait
          s.wait_until(timeout: timeout, message: "the connection") { s.connected? }
          s.wait_for_input(timeout: timeout)
        end
      rescue StandardError
        s.close
        raise
      end
      return s unless block

      begin
        yield s
      ensure
        s.close
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

    # The script port of the ruby3270 tab this session is attached to: ask,
    # choose, show and notify go to that tab's window. nil: the window in front.
    attr_accessor :window_port

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

    # The screen as text, one line per row, hidden fields blanked. Asked of
    # the engine as plain text: much cheaper than building a Screen, which
    # matters to the waits below (they look several times a second).
    def text = @engine.run("Ascii()").join("\n")
    def include?(needle) = text.include?(needle)
    def fields = screen.fields
    def input_fields = screen.input_fields
    def field_at(row, col) = screen.field_at(row, col)

    # Text at a position (0-based row/col).
    def read(row, col, length)
      @engine.run("Ascii(#{row},#{col},#{length})").join
    end

    # ---- typing --------------------------------------------------------------

    # Types text at the cursor. A line break in it presses Newline: the rest
    # goes in the next line's input field.
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
      wait_for_host if wait && name.match?(AID)
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
      poll(timeout, needle.inspect) { on_screen?(needle) }
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
      poll(timeout, "#{needle.inspect} to go away") { !on_screen?(needle) }
    end

    # Waits until the screen is different from the one given (or from now).
    #   before = s.screen
    #   s.enter(wait: false)
    #   s.wait_for_change(before)
    def wait_for_change(before = screen, timeout: @timeout)
      old = before.is_a?(Screen) ? before.text : before.to_s
      poll(timeout, "the screen to change") { text != old }
    end

    # Presses a key, then waits for the host: for `text` to appear when given,
    # otherwise for the screen to change. Returns the session.
    #   s.press_and_wait(:enter, "READY")
    #   s.press_and_wait(:pf8)               # next page
    def press_and_wait(key, needle = nil, timeout: @timeout)
      before = text
      press(key, wait: false)
      needle ? wait_for_text(needle, timeout: timeout) : wait_for_change(before, timeout: timeout)
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
    def line(row) = @engine.run("Ascii()")[row].to_s.rstrip

    # Every row as an array of strings, trailing blanks removed.
    def lines = @engine.run("Ascii()").map(&:rstrip)

    # Where text appears: [[row, col, length], ...]. Rows and columns are 0-based.
    def find(term, match_case: false) = screen.find(term, match_case: match_case)

    # Whether text (or a Regexp) is on the screen now.
    def on_screen?(needle) = needle.is_a?(Regexp) ? text.match?(needle) : text.include?(needle)

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

        before = text
        press(key, wait: false)
        wait_for_host(timeout: timeout)
        return on_screen?(needle) if text == before
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

    # ---- talking to the person at ruby3270 --------------------------------
    # These open their own small windows over the session's ruby3270 window
    # (the one in front for a session that isn't attached), so nothing goes
    # into the 3270 screen and the 3270 keyboard is never touched. They need
    # ruby3270 running with single_instance on. Each waits as long as the
    # person takes. Cancel gives nil; Stop Script raises Tn3270::ScriptStopped.

    # A line of text from the user, or nil if they cancel.
    #   job = s.ask("Job name?", default: "USER01A")
    # secret: true hides what's typed (for a password).
    def ask(prompt, default: "", title: nil, secret: false)
      user_request("kind" => "ask", "prompt" => prompt.to_s, "default" => default.to_s,
                   "title" => title&.to_s, "secret" => secret)["value"]
    end

    # One of `options` (strings), as the user picked it, or nil if they cancel.
    #   lpar = s.choose("Which system?", %w[PROD TEST DEV], default: "TEST")
    def choose(prompt, options, default: nil, title: nil)
      list = options.map(&:to_s)
      raise ArgumentError, "choose needs at least one option" if list.empty?

      answer = user_request("kind" => "choose", "prompt" => prompt.to_s, "options" => list,
                            "default" => default&.to_s, "title" => title&.to_s)["value"]
      list.include?(answer) ? answer : nil
    end

    # Shows text in a window of its own (read-only; it can be copied from).
    # Showing again with the same title replaces the text in that window,
    # so it can show progress. wait: true waits until the user closes it.
    #   s.show(report_lines.join("\n"), title: "Data sets")
    def show(text, title: "Script", wait: false)
      tap { user_request("kind" => "show", "text" => text.to_s, "title" => title.to_s, "wait" => wait) }
    end

    # A short message in the tab's status bar.
    def notify(text)
      tap { user_request("kind" => "notify", "text" => text.to_s.lines.first.to_s.chomp) }
    end

    private

    def user_request(ui)
      require_relative "gui/instance"
      reply = Gui::Instance.user_request(ui.merge("port" => window_port).compact)
      raise ScriptStopped, "Stopped by the user" if reply["stop"]

      reply
    end

    # Looks every 0.1 seconds until the block is true; TimeoutError after `timeout`.
    def poll(timeout, what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until yield
        raise TimeoutError, "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.1
      end
      self
    end
  end
end
