# frozen_string_literal: true

require_relative "../session"
require_relative "config"

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

      attr_reader :snapshot, :message, :insert_mode, :history, :rows, :cols, :last_target, :response_time

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
        @session = new_session(config["rows"], config["cols"])
        @worker = Thread.new { work }
      end

      def connected? = @snapshot&.status&.connected?

      # True between asking to connect and the host answering (or giving up).
      def connecting?
        return false if connected? || @connecting_since.nil?

        Time.now - @connecting_since < CONNECT_TIMEOUT
      end

      # ---- requests from the UI (any thread) -----------------------------------

      # `target` is a connection hash from the config, or a "host:port" string.
      def connect(target)
        conn = target.is_a?(Hash) ? target : Config.connection_from_string(target, rows: @config["rows"], cols: @config["cols"])
        @last_target = conn
        @connecting_since = Time.now
        notify
        enqueue do
          @session.disconnect if connected?
          rows = conn["rows"].to_i
          cols = conn["cols"].to_i
          if rows.positive? && cols.positive? && [rows, cols] != [@rows, @cols]
            @session.close
            @session = new_session(rows, cols)
          end
          @session.connect(Config.connect_string(conn), wait: false)
        end
      end

      def disconnect
        @connecting_since = nil
        enqueue do
          @typeahead.clear
          @aid_sent_at = nil
          @session.disconnect
        end
      end

      def type(text) = enqueue(input: true) { type_checked(text) }
      def move_to(row, col) = enqueue(input: true) { @session.move_to(row, col) }

      # Keys that must get through a locked keyboard rather than wait.
      IMMEDIATE = %i[reset attn sysreq].freeze

      def press(key)
        enqueue(input: !IMMEDIATE.include?(key)) do
          @insert_mode = !@insert_mode if key == :insert
          @aid_sent_at = nil if key == :reset # stop waiting for the host
          if key.to_s.match?(AID)
            refresh # catch keystrokes typed since the last poll
            remember
            @records_before = records_received
            @aid_sent_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
          @session.press(key, wait: false)
          notify if @aid_sent_at # show "X SYSTEM" while the host works
        end
      end

      # Waiting for the host to answer an AID key.
      def waiting_for_host? = !@aid_sent_at.nil?

      # Pasted lines go into successive input fields.
      def paste(text)
        enqueue(input: true) do
          text.split("\n").each_with_index do |line, i|
            @session.press(:newline, wait: false) if i.positive?
            @session.type(line) unless line.empty?
          end
        end
      end

      def screen_text = @snapshot&.text.to_s

      def shutdown
        @queue << :stop
        @worker.join(3)
        @session.close
      end

      private

      def new_session(rows, cols)
        @rows = rows
        @cols = cols
        @snapshot = nil
        @signature = nil
        Session.new(rows: rows, cols: cols, exe: @config["engine"])
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
        st&.connected? && st.error?
      end

      # ---- worker thread -------------------------------------------------------

      def work
        poll_every = @config["poll_ms"] / 1000.0
        loop do
          waiting = @aid_sent_at || @typeahead.any?
          job = pop(waiting ? FAST_POLL : poll_every)
          break if job == :stop

          # Run this job and any that queued up behind it before redrawing.
          while job && job != :stop
            handle(job)
            job = pop(0)
          end
          break if job == :stop

          refresh
          flush_typeahead
        end
      end

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
        @message = e.message.sub(/\A\w+\(.*?\): /, "")
        notify
      end

      def refresh
        time_response
        lines = @session.engine.run("ReadBuffer(Ascii)")
        status = @session.engine.last_status
        sig = [lines, status&.raw.to_s.split[0..9], @insert_mode].hash
        return if sig == @signature

        @signature = sig
        @raw = [lines, status]
        @snapshot = Screen.from_buffer(lines, status)
        @connecting_since = nil if @snapshot.status&.connected?
        notify
      rescue Error => e
        @message = e.message
        notify
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
