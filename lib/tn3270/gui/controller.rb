# frozen_string_literal: true

require_relative "../session"
require_relative "config"
require_relative "startup_script"
require_relative "paste"
require_relative "../snippet"

module Tn3270
  module Gui
    # Everything the window does, minus the drawing. All engine calls happen
    # on one worker thread, so a slow host never freezes the window. The
    # worker polls the screen and calls `on_change` when something changed.
    #
    # Screen history: each time an AID key (Enter, PFn, Clear...) is sent, the
    # screen as it was just before is saved, so you can page back through
    # earlier screens. Entries keep the raw buffer text (a few KB each) and
    # are only parsed into a Screen when shown.
    #
    # Type-ahead: keys pressed while the host is busy (after Enter or another
    # AID key, until it answers) are queued and sent, in order, once it has.
    # s3270 does not report that wait as a keyboard lock, so "answered" means
    # the host has sent a new record (its receive counter went up).
    #
    # Response time: how long the host took to answer the last AID key.
    #
    # Startup script: a connection's "script" runs once each time it comes
    # up (see StartupScript).
    class Controller
      AID = /\A(pf\d+|pa\d|enter|clear|attn|sysreq)\z/
      CONNECT_TIMEOUT = 20
      TYPEAHEAD_MAX = 500
      FAST_POLL = 0.03 # seconds, while waiting for the host or holding type-ahead
      NUMERIC_OK = /\A[0-9.\-]*\z/
      ANSWER_TIMEOUT = 120 # seconds before giving up on a host answer

      # A queued request. `input` jobs are keystrokes, which wait for an
      # unlocked keyboard; the others (connect, reset...) run right away.
      Job = Struct.new(:block, :input)

      HistoryEntry = Struct.new(:lines, :status, :time) do
        def screen = Screen.from_buffer(lines, status)
      end

      attr_reader :attach_port, :snapshot, :message, :insert_mode, :history, :rows, :cols, :last_target, :response_time,
                  :last_heard # when the host last sent data (a Time), or nil

      # Keystrokes waiting for the keyboard to unlock.
      def typeahead_count = @typeahead.size

      def initialize(config, on_change:)
        @config = config
        @on_change = on_change
        @queue = Queue.new
        @snapshot = nil
        @signature = nil
        @message = nil
        @insert_mode = false
        @history = []
        @raw = nil # [lines, status] behind @snapshot
        @connecting_since = nil
        @last_target = nil
        @typeahead = []
        @aid_sent_at = nil
        @response_time = nil
        @rows = config["rows"]
        @cols = config["cols"]
        @session = nil # the engine starts on the worker, so a new tab opens at once
        @worker = Thread.new { work }
      end

      def connected? = @snapshot&.status&.connected?

      # True between asking to connect and the host answering (or giving up).
      def connecting?
        return false if connected? || @connecting_since.nil?

        Time.now - @connecting_since < connect_timeout
      end

      # ---- requests from the UI (any thread) -----------------------------------

      # `target` is a connection hash from the config, or a "host:port" string.
      def connect(target)
        conn = target.is_a?(Hash) ? target : Config.connection_from_string(target, rows: @config["rows"], cols: @config["cols"])
        @last_target = conn
        @connecting_since = Time.now
        watch_connect(conn)
        notify
        enqueue do
          stop_startup_script
          @session.disconnect if connected?
          @script_wants_port = !StartupScript.path_for(conn).nil? # the script attaches through it
          rows = conn["rows"].to_i
          cols = conn["cols"].to_i
          resize = rows.positive? && cols.positive? && [rows, cols] != [@rows, @cols]
          if resize || attach_changed?
            @session.close
            @session = new_session(resize ? rows : @rows, resize ? cols : @cols)
          end
          @session.connect(Config.connect_string(conn), wait: false)
          @script_conn = StartupScript.path_for(conn) ? conn : nil
        end
      end

      # The session's saved settings changed (Session > Edit Session): the
      # tab shows the new name now; the rest applies at the next connect.
      def retarget(conn)
        @last_target = conn if @last_target
        notify
      end

      # Session > Allow Scripts to Attach was switched. Applies now when not
      # connected, otherwise at the next connect.
      def attach_setting_changed
        enqueue do
          if connected?
            @message = "Scripts can attach after the next connect" if wanted_port
          else
            @session.close
            @session = new_session(@rows, @cols)
          end
          notify
        end
      end
      
      def disconnect
        @connecting_since = nil
        enqueue do
          @script_conn = nil
          stop_startup_script
          @typeahead.clear
          @aid_sent_at = nil
          @session.disconnect
        end
      end

      def type(text) = enqueue(input: true) { type_checked(text) }
      def move_to(row, col) = enqueue(input: true) { @session.move_to(row, col) }

      # Shows a message in the status bar (until the next one).
      def flash(text)
        @message = text
        notify
      end

      # Replaces the word `old` starting at row, col with `new` (a spelling
      # fix). The rest of the field moves to fit; if it won't fit, nothing
      # changes and the status bar says so. The cursor ends after the new word.
      def replace_word(row, col, old, new)
        enqueue(input: true) do
          screen = @session.screen
          field = screen.field_at(row, col)
          offset = ((row * screen.cols) + col) - ((field.row * screen.cols) + field.col) if field
          if !field&.input? || field.value.to_s[offset, old.size] != old
            @message = "The word changed before it could be replaced"
            next notify
          end

          tail = field.value.to_s[(offset + old.size)..].to_s.rstrip
          if offset + new.size + tail.size > field.length
            @message = "No room in the field for \"#{new}\""
            next notify
          end

          @session.move_to(row, col)
          @session.press(:erase_eof, wait: false)
          @session.type(new + tail)
          @session.move_to(*(((row * screen.cols) + col + new.size) % (screen.rows * screen.cols)).divmod(screen.cols))
          @message = nil
        end
      end

      # Keys that must get through a locked keyboard rather than wait.
      # :escape is Reset while the keyboard is locked, otherwise Clear (see press).
      IMMEDIATE = %i[reset attn sysreq escape].freeze

      def press(key)
        enqueue(input: !IMMEDIATE.include?(key)) do
          was_locked = locked?
          key = was_locked ? :reset : :clear if key == :escape
          @insert_mode = !@insert_mode if key == :insert
          reset_keyboard if key == :reset
          send_key(key)
          cursor_to_input_field if key == :reset && was_locked
        end
      end

      # After a Reset unlocks the keyboard: if the cursor sits where you can't
      # type (the usual cause of X -f), Tab it to the next input field.
      def cursor_to_input_field
        screen = @session.screen
        return if screen.input_fields.empty?
        return if screen.field_at(screen.cursor_row, screen.cursor_col)&.input?

        @session.press(:tab, wait: false)
      rescue Error
        nil
      end

      # The keyboard won't take keys: the host hasn't answered yet, it locked
      # the keyboard (X SYSTEM), or an error locked it (X -f).
      def locked?
        return false unless connected?

        host_busy? || keyboard_error? || @typeahead.any?
      end

      # Reset: stop waiting for the host and drop the keys queued meanwhile,
      # so they don't all go off once the keyboard unlocks.
      def reset_keyboard
        @aid_sent_at = nil
        dropped = @typeahead.size
        @typeahead.clear
        @message = "Reset - #{dropped} queued key#{'s' unless dropped == 1} dropped" if dropped.positive?
      end

      # On the worker thread: sends a key. AID keys save the screen to the
      # history first and start the response timer.
      def send_key(key)
        if key.to_s.match?(AID)
          refresh # catch keystrokes typed since the last poll
          remember
          @records_before = records_received
          @aid_sent_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
        @session.press(key, wait: false)
        notify if @aid_sent_at # show "X SYSTEM" while the host works
      end

      # A key inside a snippet: like a key press, and for Enter, PF, PA and
      # friends, waits for the host to answer before the snippet goes on.
      def snippet_key(key)
        @insert_mode = !@insert_mode if key == :insert
        send_key(key)
        return unless key.to_s.match?(AID)

        @session.wait_for_host(timeout: @config["snippet_wait_seconds"].to_f)
        refresh # stops the response timer and shows the answer
      end

      # Waiting for the host to answer an AID key.
      def waiting_for_host? = !@aid_sent_at.nil?

      # ---- auto Enter: for watching a job finish -----------------------------------
      # While on, Enter is pressed, the host's answer awaited, and Enter
      # pressed again auto_enter_seconds (default 2) after that answer. It stops
      # by itself on disconnect or when the keyboard locks with an error.

      def auto_enter? = @auto_enter || false

      def auto_enter=(on)
        @auto_enter = on ? true : false
        @auto_enter_at = nil
        @message = on ? "AUTO ENTER every #{auto_enter_seconds.round(1)}s - click ENTER again to stop" : nil
        notify
      end

      def auto_enter_seconds = (@config["auto_enter_seconds"] || 2).to_f

      # Pastes text at the cursor. Several lines line up under the cursor's
      # column, one row down each (see Paste).
      def paste(text)
        enqueue(input: true) do
          screen = @session.screen
          steps, note = Paste.plan(screen, screen.cursor_row, screen.cursor_col, text.delete("\r").split("\n"))
          steps.each { |op, *args| op == :move ? @session.move_to(*args) : @session.type(*args) }
          @message = note if note
        end
      end

      # Types a snippet (see Tn3270::Snippet): it waits its turn like typed
      # keys, keys in it go into the screen history like keys you press, and
      # the window redraws after each step. Errors show in the status bar.
      def run_snippet(text, answers: {}, vars: {}, name: nil)
        enqueue(input: true) do
          Snippet.run(@session, text, answers: answers, vars: vars,
                                      wait_timeout: @config["snippet_wait_seconds"].to_f,
                                      press: ->(key) { snippet_key(key) }, after: -> { refresh })
        rescue Error => e
          raise Error, "Snippet #{name ? "\"#{name}\" " : ''}stopped: #{e.message.sub(/\A\w+\(.*?\): /, '')}"
        end
      end

      def screen_text = @snapshot&.text.to_s

      # Stops the worker and the engine. Never raises, even when a connect is
      # stuck (the engine is then stopped rather than waited for).
      def shutdown
        @connect_attempt = nil
        @queue << :stop
        @worker.join(3)
        stop_startup_script
        @session&.close
      rescue StandardError
        nil
      end

      private

      # Engines start one at a time (every tab has its own): each takes the
      # first free attach port, and two starting together could pick the same.
      ENGINE_START = Mutex.new

      def new_session(rows, cols)
        @rows = rows
        @cols = cols
        @snapshot = nil
        @signature = nil
        ENGINE_START.synchronize { start_session(rows, cols) }
      end

      def start_session(rows, cols)
        port = attach_port_to_use
        session = no_aid_wait(Session.new(rows: rows, cols: cols, exe: @config["engine"], script_port: port))
        @attach_port = port
        session
      rescue Error => e
        raise unless port

        # The port couldn't be used: carry on, without scripts attaching.
        @message = "Scripts can't attach: #{e.message}"
        @attach_port = nil
        no_aid_wait(Session.new(rows: rows, cols: cols, exe: @config["engine"]))
      end

      # Session > Allow Scripts to Attach was switched since the engine started.
      # (Any free port will do: with several tabs, each has its own.)
      def attach_changed? = wanted_port.nil? != @attach_port.nil?

      # By default the engine's Enter, PF, PA... don't return until the host
      # answers, which would stall this worker for that long: no type-ahead,
      # and no Reset (Esc) to unlock a keyboard the host has locked. With
      # aidWait off they return at once; the worker watches for the answer.
      def no_aid_wait(session)
        session.raw("Set(aidWait,false)")
        session
      rescue Error
        session # an engine too old for the setting: carry on as before
      end

      # The port scripts attach to, when Session > Allow Scripts to Attach is
      # on or the connection has a startup script (it attaches through it).
      # Scripts (startup, from a script folder, or your own) attach through the port.
      def wanted_port
        want = @config["allow_attach"] || @script_wants_port || Array(@config["script_folders"]).any?
        want ? @config["script_port"].to_i : nil
      end

      # The first free port from the configured one, so several windows can
      # each be attached to; nil when attaching is off or no port is free.
      def attach_port_to_use
        start = wanted_port
        start && Engine.free_port(start)
      end

      def remember
        return unless connected? && @raw

        lines, status = @raw
        return if @history.last&.lines == lines

        # Replace the array rather than mutate it; the UI thread reads it.
        entry = HistoryEntry.new(lines, status, Time.now)
        @history = (@history + [entry]).last(@config["history_size"].to_i.clamp(1, 5000))
      end

      def enqueue(input: false, &block)
        @queue << Job.new(block, input)
        nil
      end

      # Types text, unless the cursor is in a numeric field and the text has
      # anything other than digits, "." or "-" (like a real 3270 terminal).
      def type_checked(text)
        if @config["numeric_lock"] && !text.match?(NUMERIC_OK)
          st = @session.engine.last_status
          field = st && @snapshot&.field_at(st.cursor_row, st.cursor_col)
          if field&.numeric && field.input?
            @message = "NUMERIC field - only 0-9 . - allowed"
            return notify
          end
        end
        @session.type(text)
      end

      # The host is busy: it has not answered the last AID key yet, or the
      # keyboard is locked (but not by an error).
      def host_busy?
        return true if @aid_sent_at

        st = @session.engine.last_status
        st&.connected? && st.keyboard_locked? && !st.error?
      end

      # Records received from the host so far (s3270 statistics).
      def records_received
        @session.engine.run("Query(StatsRx)").join[/records (\d+)/, 1].to_i
      rescue Error
        0
      end

      def keyboard_error?
        st = @session.engine.last_status
        st&.connected? && (st.error? || operator_error?)
      end

      # Locked because of something typed where it can't go (a protected spot,
      # a letter in a numeric field): "X -f" on a real terminal. The engine
      # reports it as an ordinary lock, so it's recognised by its error message
      # and remembered until the keyboard unlocks.
      def operator_error?
        return false unless @operator_error

        st = @session.engine.last_status
        @operator_error = false unless st&.connected? && st.keyboard_locked?
        @operator_error
      end
      public :operator_error? # the status bar shows it

      # ---- worker thread -------------------------------------------------------

      def work
        poll_every = @config["poll_ms"] / 1000.0
        start_engine
        loop do
          waiting = @aid_sent_at || @typeahead.any?
          job = pop(waiting ? FAST_POLL : poll_every)
          break if job == :stop
          next unless @session || start_engine # couldn't start: jobs wait for one that can

          # Run this job and any that queued up behind it before redrawing.
          while job && job != :stop
            handle(job)
            job = pop(0)
          end
          break if job == :stop

          refresh
          run_startup_script
          flush_typeahead
          auto_enter_tick
        end
      end

      # Starts the engine (tried again every few seconds if it fails, e.g. no
      # ws3270 installed). Returns the session, or nil.
      def start_engine
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return nil if @engine_tried_at && now - @engine_tried_at < 5

        @engine_tried_at = now
        @session = new_session(@rows, @cols)
      rescue Error => e
        @message = e.message
        nil
      ensure
        notify
      end

      # The auto Enter loop's next step, checked on every poll.
      def auto_enter_tick
        return unless @auto_enter

        unless connected?
          @auto_enter = false
          @message = "AUTO ENTER stopped: not connected"
          return notify
        end
        if keyboard_error?
          @auto_enter = false
          @message = "AUTO ENTER stopped: keyboard locked (X -f). Press Reset."
          return notify
        end
        return if host_busy? || @typeahead.any?

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @auto_enter_at ||= now + auto_enter_seconds # the host has answered: start the pause
        return if now < @auto_enter_at

        @auto_enter_at = nil
        run_safely { send_key(:enter) }
        @message = "AUTO ENTER every #{auto_enter_seconds.round(1)}s - click ENTER again to stop" if @auto_enter && @message.nil?
      end

      # Starts the startup script once the connection is up, in its own
      # process: the window stays usable while it works. Each line it prints,
      # or its error, shows in the status bar.
      def run_startup_script
        return unless @script_conn && connected?

        conn = @script_conn
        @script_conn = nil
        path = StartupScript.path_for(conn)
        unless @attach_port
          @message = "Startup script not run: no free script port from #{@config['script_port']}"
          return notify
        end
        running = @message = "Running startup script #{File.basename(path)}..."
        notify
        on_status = lambda do |text|
          @message = text
          notify
        end
        on_exit = lambda do |error|
          @message = error || (@message == running ? nil : @message) # a quiet script leaves no message
          notify
        end
        @startup_script = StartupScript.start(path, conn, @attach_port, on_status: on_status, on_exit: on_exit)
      end

      def stop_startup_script
        StartupScript.stop(@startup_script)
        @startup_script = nil
        (@scripts || []).each { |s| StartupScript.stop(s) } # ones run from the snippet list
        @scripts = []
      end

      public

      # Runs a script from a script folder against this session, in the
      # background, like a startup script: what it prints shows in the
      # status bar, and it ends when the tab disconnects, reconnects or closes.
      def run_script(path, name)
        enqueue do
          if !connected?
            @message = "Connect first, then run \"#{name}\""
          elsif !@attach_port
            @message = "\"#{name}\" not run: the session has no script port yet. Reconnect to open one"
          else
            start_script(path, name)
          end
          notify
        end
      end

      private

      def start_script(path, name)
        running = @message = "Running #{name}..."
        on_status = lambda do |text|
          @message = text
          notify
        end
        on_exit = lambda do |error|
          @message = error ? error.sub(StartupScript::FAILED, "#{name} failed").sub("Startup script", name) : (@message == running ? nil : @message)
          notify
        end
        @scripts = (@scripts || []).select(&:alive?)
        run = StartupScript.start(path, @last_target || {}, @attach_port, on_status: on_status, on_exit: on_exit)
        @scripts << run if run
      end

      public

      # True while this tab's startup script is still running.
      def startup_script_running? = @startup_script&.alive? || false

      private

      def handle(job)
        if job.input && @config["typeahead"] && (@typeahead.any? || host_busy?)
          @typeahead << job if @typeahead.size < TYPEAHEAD_MAX
          notify
        else
          run_safely(&job.block)
        end
      end

      # Sends queued keystrokes once the host has unlocked the keyboard. An
      # error lock (X -f) throws them away, as a real terminal does.
      def flush_typeahead
        return if @typeahead.empty?

        if keyboard_error?
          @typeahead.clear
          @message = "Keyboard locked - type-ahead discarded. Press Reset."
          return notify
        end
        until @typeahead.empty? || host_busy?
          run_safely(&@typeahead.shift.block)
          refresh
        end
        notify
      end

      def pop(timeout)
        @queue.pop(timeout: timeout)
      end

      def run_safely
        @message = nil
        yield
      rescue Error, ArgumentError => e
        @connecting_since = nil
        if e.message.match?(/operator error/i)
          @operator_error = true
          @message = "Keyboard locked: you can't type there. Reset unlocks it."
          return notify
        end
        @message = @gave_up || explain(e.message.sub(/\A\w+\(.*?\): /, ""))
        @gave_up = nil
        revive_engine
        notify
      end

      TLS_TIP = "If the host doesn't use TLS, untick Use TLS in Session > Connections."

      # Engine messages in plain words where we can: a TLS handshake error
      # usually means the host doesn't use TLS on that port.
      def explain(message)
        return message unless message.include?("TLS") && @last_target&.dig("tls")

        "Could not connect to #{Config.display_string(@last_target)}: the TLS handshake failed. #{TLS_TIP} " \
          "(#{message.sub(/\AConnection failed: /, '')})"
      end

      # Seconds to wait for a connection (config "connect_timeout").
      def connect_timeout = (@config["connect_timeout"] || CONNECT_TIMEOUT).to_f

      # After the engine has stopped (crashed, or stopped by watch_connect),
      # starts a fresh one so the window keeps working.
      def revive_engine
        return if @session.engine.alive?

        @session.close
        @session = new_session(@rows, @cols)
      rescue Error => e
        @message = e.message
      end

      # A connect that hangs (for example TLS to a host that doesn't use it:
      # the handshake never finishes) would block the worker for good. After
      # connect_timeout seconds, stop the engine; the stuck action then fails
      # and run_safely shows why and starts a new engine.
      def watch_connect(conn)
        attempt = @connect_attempt = @connect_attempt.to_i + 1
        Thread.new do
          sleep connect_timeout
          next unless @connect_attempt == attempt && @connecting_since && !connected?

          where = Config.display_string(conn)
          tip = conn["tls"] ? " #{TLS_TIP}" : ""
          @gave_up = "Could not connect to #{where}: no answer in #{connect_timeout.round} seconds.#{tip}"
          @connecting_since = nil
          @session.engine.kill
          notify
        end
      end

      def refresh
        lines = @session.engine.run("ReadBuffer(Ascii)")
        status = @session.engine.last_status
        # After reading the screen, so a screen with the host's answer is never
        # shown while the keyboard still counts as waiting for it.
        time_response
        sig = [lines, status&.raw.to_s.split[0..9], @insert_mode].hash
        return if sig == @signature

        @signature = sig
        note_heard(status)
        @raw = [lines, status]
        @snapshot = Screen.from_buffer(lines, status)
        @connecting_since = nil if @snapshot.status&.connected?
        notify
      rescue Error => e
        @message = @gave_up || e.message
        @gave_up = nil
        revive_engine
        notify
      end

      # When the screen changed: if the host sent something, notes the time
      # (last_heard, shown in the status bar). Typing changes the screen too,
      # so the host's record count decides.
      def note_heard(status)
        return @rx_count = nil unless status&.connected?

        count = records_received
        @last_heard = Time.now if @rx_count.nil? ? count.positive? : count > @rx_count
        @rx_count = count
      end

      # Stops the response timer when the host answers the last AID key.
      def time_response
        return unless @aid_sent_at

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @aid_sent_at
        status = @session.engine.last_status
        if !status&.connected? || elapsed > ANSWER_TIMEOUT
          @aid_sent_at = nil
        elsif status.error? || records_received > @records_before
          @response_time = elapsed
          @aid_sent_at = nil
          @signature = nil # make sure the status bar redraws
        end
      end

      def notify = @on_change.call
    end
  end
end
