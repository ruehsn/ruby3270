# frozen_string_literal: true

require "socket"

module Tn3270
  # A tiny TN3270 host for testing without a mainframe.
  #
  # It speaks plain TN3270 (not TN3270E), asks the terminal for its screen
  # size with a Read Partition Query, then serves these screens:
  #   LOGIN -> MENU -> KEYS (a key tester that shows the last AID pressed),
  #                    COLORS, or EDIT (an ISPF-style editor, see below).
  # PF3 goes back, PF12 or "LOGOFF" disconnects.
  #
  # EDIT works like ISPF EDIT: each row is a line-number field (columns 0-5,
  # takes line commands: I inserts a line, D deletes one) and a data field
  # (columns 7 to the second last). Enter keeps changes, PF7/PF8
  # scroll, PF3 saves and goes back, RESET in the command line starts over.
  class FakeHost
    IAC = 0xFF; DONT = 0xFE; DO = 0xFD; WONT = 0xFC; WILL = 0xFB
    SB = 0xFA; SE = 0xF0; EOR = 0xEF
    OPT_BINARY = 0x00; OPT_TTYPE = 0x18; OPT_EOR = 0x19

    CMD_EW = 0xF5; CMD_EWA = 0x7E; CMD_WSF = 0xF3
    ORD_SBA = 0x11; ORD_SF = 0x1D; ORD_SFE = 0x29; ORD_IC = 0x13

    # 6-bit value -> printable EBCDIC (used for attribute bytes and WCC).
    CODE_TABLE = [
      0x40, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F,
      0x50, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F,
      0x60, 0x61, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F,
      0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F
    ].freeze

    COLORS = { blue: 0xF1, red: 0xF2, pink: 0xF3, green: 0xF4, turquoise: 0xF5, yellow: 0xF6, white: 0xF7 }.freeze

    AID_NAMES = { 0x7D => "ENTER", 0x6D => "CLEAR", 0x6C => "PA1", 0x6E => "PA2", 0x6B => "PA3" }.tap do |h|
      [0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0x7A, 0x7B, 0x7C].each_with_index { |a, i| h[a] = "PF#{i + 1}" }
      [0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0x4A, 0x4B, 0x4C].each_with_index { |a, i| h[a] = "PF#{i + 13}" }
    end.freeze

    # Field attribute bits
    PROTECTED = 0x20; NUMERIC = 0x10; BRIGHT = 0x08; HIDDEN = 0x0C

    attr_reader :port

    def initialize(port: 3270, bind: "127.0.0.1", log: $stderr)
      @port = port
      @bind = bind
      @log = log
    end

    def start
      @server = TCPServer.new(@bind, @port)
      @port = @server.addr[1]
      @log&.puts "FakeHost listening on #{@bind}:#{@port}"
      @thread = Thread.new do
        loop do
          client = @server.accept
          Thread.new(client) { |c| Connection.new(c, @log).run }
        rescue IOError, Errno::EBADF
          break
        end
      end
      self
    end

    def stop
      @server&.close
      @thread&.join(1)
    end

    def run_forever
      start
      @thread.join
    end

    # One terminal session.
    class Connection
      def initialize(sock, log)
        @sock = sock
        @log = log
        @rows = 24
        @cols = 80
        @alternate = false
        @screen = :login
        @user = nil
        @last_aid = "(none)"
        @last_fields = {}
        @edit_lines = SAMPLE_SOURCE.dup
        @edit_top = 0
      end

      SAMPLE_SOURCE = [
        "//APPCIN   JOB (TEST),'FAKEHOST',CLASS=A,MSGCLASS=X",
        "//*",
        "//ASM      EXEC ASMACLG",
        "//SYSIN    DD *",
        "         YREGS",
        "APPCIN   CSECT",
        "APPCIN   AMODE 31",
        "         BR    14",
        "         END   APPCIN",
        "/*"
      ].freeze

      def run
        negotiate
        query_size
        show
        loop do
          rec = read_record or break
          handle_input(rec) or break
        end
      rescue IOError, Errno::ECONNRESET, Errno::EPIPE
        nil
      ensure
        @sock.close unless @sock.closed?
      end

      # ---- telnet ----------------------------------------------------------

      def negotiate
        send_raw [IAC, DO, OPT_TTYPE]
        expect_option_reply
        send_raw [IAC, SB, OPT_TTYPE, 0x01, IAC, SE]
        ttype = read_subnegotiation
        @log&.puts "Terminal type: #{ttype}"
        send_raw [IAC, DO, OPT_EOR, IAC, WILL, OPT_EOR, IAC, DO, OPT_BINARY, IAC, WILL, OPT_BINARY]
        4.times { expect_option_reply }
      end

      def expect_option_reply
        loop do
          b = @sock.readbyte
          next unless b == IAC

          cmd = @sock.readbyte
          if [WILL, WONT, DO, DONT].include?(cmd)
            @sock.readbyte
            return
          end
        end
      end

      def read_subnegotiation
        bytes = []
        loop do
          b = @sock.readbyte
          if b == IAC
            n = @sock.readbyte
            next if n == SB
            break if n == SE
          else
            bytes << b
          end
        end
        bytes.drop(2).pack("C*") # drop option + IS
      end

      # Reads one 3270 record (everything up to IAC EOR), skipping telnet commands.
      def read_record
        data = []
        loop do
          b = @sock.readbyte
          if b == IAC
            n = @sock.readbyte
            case n
            when EOR then return data
            when IAC then data << 0xFF
            when WILL, WONT, DO, DONT then @sock.readbyte
            end
          else
            data << b
          end
        end
      rescue EOFError
        nil
      end

      def send_raw(bytes) = @sock.write(bytes.pack("C*"))

      def send_record(bytes)
        escaped = bytes.flat_map { |b| b == IAC ? [IAC, IAC] : [b] }
        send_raw(escaped + [IAC, EOR])
      end

      # ---- screen size -------------------------------------------------------

      # Read Partition Query; the reply's Usable Area tells us rows/cols.
      def query_size
        send_record [CMD_WSF, 0x00, 0x05, 0x01, 0xFF, 0x02]
        reply = read_record
        return unless reply && reply.first == 0x88

        i = 1
        while i + 3 < reply.size
          len = (reply[i] << 8) | reply[i + 1]
          break if len < 4

          if reply[i + 2] == 0x81 && reply[i + 3] == 0x81 # Usable Area
            @cols = (reply[i + 6] << 8) | reply[i + 7]
            @rows = (reply[i + 8] << 8) | reply[i + 9]
            @alternate = true
          end
          i += len
        end
        @log&.puts "Screen size: #{@rows}x#{@cols}"
      end

      # ---- 3270 output -------------------------------------------------------

      def addr_bytes(row, col)
        a = (row * @cols) + col
        if @rows * @cols > 4096
          [(a >> 8) & 0x3F, a & 0xFF] # 14-bit binary
        else
          [CODE_TABLE[(a >> 6) & 0x3F], CODE_TABLE[a & 0x3F]] # 12-bit coded
        end
      end

      def decode_addr(b1, b2)
        (b1 & 0xC0).zero? ? ((b1 & 0x3F) << 8) | b2 : ((b1 & 0x3F) << 6) | (b2 & 0x3F)
      end

      def ebcdic(text) = text.encode("IBM037", invalid: :replace, undef: :replace).bytes

      # Builder: list of [:text, row, col, str, attrs] / [:input, row, col, len, name, attrs]
      def render(items, cursor:)
        out = [@alternate ? CMD_EWA : CMD_EW, CODE_TABLE[0x03]] # WCC: restore kbd + reset MDT
        @inputs = []
        items.each do |item|
          kind, row, col = item
          out += [ORD_SBA, *addr_bytes(row, col)]
          if kind == :text
            _, _, _, str, opts = item
            out += field_start(PROTECTED | (opts[:bright] ? BRIGHT : 0), opts[:color])
            out += ebcdic(str)
          else
            _, _, _, len, name, opts = item
            bits = (opts[:hidden] ? HIDDEN : BRIGHT) | (opts[:numeric] ? NUMERIC : 0)
            out += field_start(bits, opts[:color] || :green)
            @inputs << [name, (row * @cols) + col + 1, len]
            out += ebcdic(opts[:value].to_s.ljust(len)[0, len]) if len.positive?
            end_col = col + 1 + len
            r, c = end_col.divmod(@cols)
            out += [ORD_SBA, *addr_bytes(row + r, c)] + field_start(PROTECTED, nil) if row + r < @rows
          end
        end
        out += [ORD_SBA, *addr_bytes(*cursor), ORD_IC]
        send_record(out)
      end

      def field_start(bits, color)
        return [ORD_SF, CODE_TABLE[bits & 0x3F]] unless color

        [ORD_SFE, 0x02, 0xC0, CODE_TABLE[bits & 0x3F], 0x42, COLORS.fetch(color)]
      end

      def text(r, c, s, **o) = [:text, r, c, s, o]
      def input(r, c, len, name, **o) = [:input, r, c, len, name, o]

      def header(title)
        line = "=" * (@cols - 2)
        [
          text(0, 1, "FAKEHOST", color: :turquoise, bright: true),
          text(0, (@cols - title.size) / 2, title, color: :white, bright: true),
          text(0, @cols - 20, "#{@rows}x#{@cols}".rjust(18), color: :yellow),
          text(1, 0, line, color: :blue)
        ]
      end

      def footer(keys) = [text(@rows - 1, 1, keys, color: :turquoise)]

      def show(message = nil)
        msg = message ? [text(@rows - 3, 1, message, color: :red, bright: true)] : []
        case @screen
        when :login
          render header("SIGN ON") + [
            text(4, 4, "Welcome to the FakeHost test system. Any user ID and password will work."),
            text(7, 4, "USER ID  ===>", color: :green),
            input(7, 18, 8, :user),
            text(9, 4, "PASSWORD ===>", color: :green),
            input(9, 18, 8, :password, hidden: true)
          ] + msg + footer("ENTER=Sign on   PF12=Disconnect"), cursor: [7, 19]
        when :menu
          ruler = (1..@cols).map { |n| (n % 10).zero? ? ((n / 10) % 10).to_s : (n % 5).zero? ? "+" : "." }.join
          render header("MAIN MENU") + [
            text(3, 4, "Signed on as #{@user}"),
            text(5, 4, "1  Key tester    - shows which AID key the host received", color: :green),
            text(6, 4, "2  Color chart   - field colors and intensities", color: :green),
            text(7, 4, "3  Wide screen   - ruler across the full width", color: :green),
            text(8, 4, "4  Slow host     - key tester that answers after 2 seconds", color: :green),
            text(9, 4, "5  Editor        - ISPF-style edit screen (line numbers + data), for paste", color: :green),
            text(10, 4, "OPTION ===>", color: :white, bright: true),
            input(10, 16, 20, :option),
            text(@rows - 5, 0, ruler[0, @cols - 1], color: :yellow)
          ] + msg + footer("ENTER=Select   PF3=Sign off   PF12=Disconnect"), cursor: [10, 17]
        when :keys
          render header(@slow ? "KEY TESTER (SLOW HOST)" : "KEY TESTER") + [
            text(4, 4, "Press any AID key: Enter, Clear, PF1-PF24, PA1-PA3."),
            text(6, 4, "Last AID received:", color: :green),
            text(6, 24, @last_aid.ljust(10), color: :yellow, bright: true),
            text(8, 4, "Typed text:", color: :green),
            input(8, 16, 40, :typed),
            text(10, 4, "Host saw:", color: :green),
            text(10, 16, (@last_fields[:typed] || "").ljust(40), color: :white),
            text(12, 4, "Numeric only:", color: :green),
            input(12, 18, 6, :num, numeric: true)
          ] + msg + footer("PF3=Back   PF12=Disconnect"), cursor: [8, 17]
        when :colors
          items = header("COLOR CHART")
          COLORS.keys.each_with_index do |c, i|
            items << text(4 + i, 4, "#{c.to_s.ljust(10)} normal", color: c)
            items << text(4 + i, 30, "#{c.to_s.ljust(10)} intensified", color: c, bright: true)
          end
          render items + msg + footer("PF3=Back"), cursor: [@rows - 1, 0]
        when :edit
          render edit_screen + msg + footer("ENTER=Keep  PF3=Save+back  PF7=Up  PF8=Down  Line cmds: I D"),
                 cursor: [3, 14]
        end
      end

      EDIT_FIRST_ROW = 5

      def edit_rows = @rows - 3 - EDIT_FIRST_ROW # leaves the message row and the footer
      # Like ISPF: line number in columns 0-5, data from column 7 to the
      # second last; the last column holds the next row's field attribute.
      def edit_width = @cols - 8

      def edit_screen
        items = header("EDIT") + [
          text(2, 0, "EDIT       FAKE.SOURCE(DEMO) - 01.00", color: :turquoise),
          text(2, @cols - 22, format("Columns 00001 %05d", edit_width), color: :turquoise),
          text(3, 0, "Command ===>", color: :green),
          input(3, 13, [@cols - 36, 8].max, :command),
          text(3, @cols - 16, "Scroll ===> CSR", color: :green),
          text(4, 0, "****** #{'*' * 20} Top of Data #{'*' * 20}", color: :blue, bright: true)
        ]
        edit_rows.times do |i|
          index = @edit_top + i
          row = EDIT_FIRST_ROW + i
          number = index < @edit_lines.size ? format("%06d", (index + 1) * 100) : ""
          items << input(row, -1, 6, [:num, index], value: number, color: :turquoise) # attribute: end of the row above
          items << input(row, 6, edit_width, [:data, index], value: @edit_lines[index].to_s)
        end
        items
      end

      # Enter on the editor: data changes, then line commands, bottom up.
      def edit_input(aid, fields)
        fields.each do |name, value|
          next unless name.is_a?(Array) && name.first == :data

          index = name.last
          @edit_lines.fill("", @edit_lines.size...index) if index > @edit_lines.size
          @edit_lines[index] = value
        end
        fields.select { |n, _| n.is_a?(Array) && n.first == :num }.sort_by { |n, _| -n.last }.each do |(_, index), cmd|
          case cmd.delete("'").strip.upcase
          when /\AD/ then @edit_lines.delete_at(index)
          when /\AI/ then @edit_lines.insert(index + 1, "")
          end
        end
        @edit_lines.pop while @edit_lines.last&.strip&.empty? && @edit_lines.size > 1
        command = fields[:command].to_s.strip.upcase
        @edit_lines = SAMPLE_SOURCE.dup if command == "RESET"
        page = edit_rows
        @edit_top = [@edit_top - page, 0].max if aid == "PF7"
        @edit_top = [@edit_top + page, [@edit_lines.size - 1, 0].max].min if aid == "PF8"
        if aid == "PF3"
          @screen = :menu
          return show("FAKE.SOURCE(DEMO) saved, #{@edit_lines.size} lines")
        end
        show(command == "RESET" ? "Back to the sample source" : nil)
      end

      # ---- input -------------------------------------------------------------

      def parse_fields(rec)
        fields = {}
        i = 3
        while i < rec.size
          if rec[i] == ORD_SBA
            addr = decode_addr(rec[i + 1], rec[i + 2])
            j = i + 3
            j += 1 while j < rec.size && rec[j] != ORD_SBA
            value = rec[i + 3...j].pack("C*").force_encoding("IBM037").encode("UTF-8").delete("\0")
            name = @inputs.find { |_, start, _| start == addr }&.first
            # Editor data keeps its leading blanks (they're columns); the rest is trimmed.
            fields[name] = name.is_a?(Array) && name.first == :data ? value.rstrip : value.strip if name
            i = j
          else
            i += 1
          end
        end
        fields
      end

      def handle_input(rec)
        aid = AID_NAMES[rec.first] || format("0x%02X", rec.first)
        fields = parse_fields(rec)
        @log&.puts "AID #{aid} #{fields.inspect}"
        return false if aid == "PF12"

        case @screen
        when :login
          if aid == "ENTER" && !fields[:user].to_s.empty?
            @user = fields[:user].upcase
            @screen = :menu
            show
          else
            show(aid == "ENTER" ? "Please enter a user ID." : "#{aid} is not active on this screen.")
          end
        when :menu
          if aid == "PF3"
            @screen = :login
            show
          elsif fields[:option].to_s.upcase == "LOGOFF"
            return false
          else
            target = { "1" => :keys, "2" => :colors, "4" => :keys, "5" => :edit }[fields[:option]]
            @slow = fields[:option] == "4"
            if target
              @screen = target
              show
            elsif fields[:option] == "3"
              show("Ruler shows columns 1-#{@cols - 1}. Every 10th column is numbered.")
            else
              show("Choose 1, 2, 3, 4 or 5.")
            end
          end
        when :edit
          edit_input(aid, fields)
        when :keys, :colors
          if aid == "PF3"
            @screen = :menu
            show
          else
            sleep 2 if @slow # pretend to be a busy host
            @last_aid = aid
            @last_fields = fields
            show
          end
        end
        true
      end
    end
  end
end
