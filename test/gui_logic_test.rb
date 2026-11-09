# frozen_string_literal: true

# Tests the GUI's keyboard mapping and background controller without
# opening a window (no libui needed):  ruby -Ilib test/gui_logic_test.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "tn3270"
require "tn3270/fake_host"
require "tn3270/gui/config"
require "tn3270/gui/keymap"
require "tn3270/gui/controller"

class KeymapTest < Minitest::Test
  K = Tn3270::Gui::Keymap

  def ev(**h) = { up: false, modifiers: [] }.merge(h)

  def test_function_keys
    assert_equal [:key, :pf1], K.translate(ev(ext_key: :f1))
    assert_equal [:key, :pf12], K.translate(ev(ext_key: :f12))
    assert_equal [:key, :pf13], K.translate(ev(ext_key: :f1, modifiers: [:shift]))
    assert_equal [:key, :pf24], K.translate(ev(ext_key: :f12, modifiers: [:shift]))
    assert_equal [:key, :pa2], K.translate(ev(ext_key: :f2, modifiers: [:ctrl]))
  end

  def test_typing_and_shift
    assert_equal [:type, "a"], K.translate(ev(key: "a"))
    assert_equal [:type, "A"], K.translate(ev(key: "a", modifiers: [:shift]))
    assert_equal [:type, "!"], K.translate(ev(key: "1", modifiers: [:shift]))
    assert_equal [:type, "7"], K.translate(ev(ext_key: :n7))
  end

  def test_editing_keys
    assert_equal [:key, :enter], K.translate(ev(key: "\n", key_value: 10))
    assert_equal [:key, :newline], K.translate(ev(key: "\n", key_value: 10, modifiers: [:shift]))
    assert_equal [:key, :backtab], K.translate(ev(key: "\t", key_value: 9, modifiers: [:shift]))
    assert_equal [:key, :escape], K.translate(ev(ext_key: :escape)) # Reset when locked, otherwise Clear
    assert_equal [:key, :erase_eof], K.translate(ev(ext_key: :end))
    assert_equal [:key, :reset], K.translate(ev(key: "r", modifiers: [:ctrl]))
    assert_equal [:paste], K.translate(ev(key: "v", modifiers: [:ctrl]))
  end

  def test_remapped_keys
    b = K.bindings("F13" => "pf13", "Escape" => "", "Ctrl+Q" => "reset")
    assert_equal [:key, :reset], K.translate(ev(key: "q", modifiers: [:control]), b)
    assert_nil K.translate(ev(ext_key: :escape), b)
    assert_equal [:key, :pf1], K.translate(ev(ext_key: :f1), b)
    assert_equal ["Ctrl+R", "Ctrl+Q"], K.keys_for(b, "reset")
  end

  def test_rebinding_a_printable_key
    b = K.bindings("`" => "pa1")
    assert_equal [:key, :pa1], K.translate(ev(key: "`"), b)
    assert_equal [:type, "x"], K.translate(ev(key: "x"), b)
  end

  def test_chord_names
    assert_equal "Ctrl+Shift+F1", K.chord(ev(ext_key: :f1, modifiers: %i[control shift]))
    assert_equal "Keypad Enter", K.chord(ev(ext_key: :n_enter))
    assert_nil K.chord(ev(key_value: 0, modifiers: [:shift])) # bare modifier
  end

  def test_history_keys
    assert_equal [:history], K.translate(ev(ext_key: :page_up, modifiers: [:control]))
    assert_equal [:history], K.translate(ev(key: "h", modifiers: [:control]))
    assert_nil K.bindings("F2" => "no_such_action")["F2"]
    assert_nil K.translate(ev(ext_key: :page_up))
  end

  def test_right_ctrl_tap
    tap = K::ModifierTap.new { |_mod| :right }
    down = ev(modifier: :control, modifiers: [:control], key_value: 0)
    up = down.merge(up: true)
    assert_nil tap.feed(down)
    assert_equal "Right Ctrl", tap.feed(up)
    assert_equal "newline", K.bindings["Right Ctrl"]

    # Right Ctrl+C is a copy, not a tap.
    tap.feed(down)
    tap.feed(ev(key: "c", key_value: 99, modifiers: [:control]))
    assert_nil tap.feed(up)

    # Without a way to tell sides, no taps are reported.
    blind = K::ModifierTap.new { nil }
    blind.feed(down)
    assert_nil blind.feed(up)
  end

  def test_ignores_key_up_and_alt
    assert_nil K.translate(ev(key: "a", up: true))
    assert_nil K.translate(ev(key: "x", modifiers: [:alt]))
  end
end

class ConfigTest < Minitest::Test
  C = Tn3270::Gui::Config

  def test_connection_strings
    c = C.connection_from_string("L:LU01@mvs.example.com:992")
    assert_equal ["mvs.example.com", 992, true, "LU01"], c.values_at("host", "port", "tls", "lu")
    # Certificates aren't verified unless the connection asks: "Y:" tells s3270 so.
    assert_equal "Y:L:LU01@mvs.example.com:992", C.connect_string(c)
    assert_equal "L:LU01@mvs.example.com:992", C.connect_string(c.merge("verify_cert" => true))
    assert_equal "L:LU01@mvs.example.com:992", C.display_string(c)
    assert_equal "h:23", C.connect_string(C.connection_from_string("h"))
    assert C.connection_from_string("Y:L:h:992")["tls"]
  end

  def test_old_hosts_list_is_migrated
    user = { "hosts" => ["a:1", "b:2"] }
    C.migrate!(user)
    assert_equal %w[a b], user["connections"].map { |c| c["host"] }
  end

  def test_model_for_size
    assert_equal "3279-5-E", Tn3270::Engine.model_for(27, 132)
    assert_equal "3279-2-E", Tn3270::Engine.model_for(62, 160)
  end
end

class RegionTest < Minitest::Test
  def test_region_text
    status = Tn3270::Status.parse("U F U C(h) I 2 3 10 0 0 0x0 -")
    scr = Tn3270::Screen.from_buffer(["41 42 43 44 20 20 20 20 20 20", "45 46 47 48 49 20 20 20 20 20",
                                      "20 20 20 20 20 20 20 20 20 20"], status)
    assert_equal "BC\nFG", scr.region_text(0, 1, 1, 2)
    assert_equal "BC\nFG", scr.region_text(1, 2, 0, 1)
    assert_equal "CD\nGHI", scr.region_text(0, 2, 1, 5)
  end

  def test_find
    status = Tn3270::Status.parse("U F U C(h) I 2 2 10 0 0 0x0 -")
    scr = Tn3270::Screen.from_buffer(["41 42 41 62 20 20 20 20 20 20", "20 61 42 20 20 20 20 20 20 20"], status)
    assert_equal [[0, 0, 2], [0, 2, 2], [1, 1, 2]], scr.find("ab")
    assert_equal [[0, 0, 2]], scr.find("AB", match_case: true)
    assert_equal [], scr.find("")
  end
end

class ControllerTest < Minitest::Test
  def setup
    @host = Tn3270::FakeHost.new(port: 0, log: nil).start
    @dir = Dir.mktmpdir
    cfg = Tn3270::Gui::Config.load(File.join(@dir, "cfg.yml"))
    cfg["allow_attach"] = false # tests must never reach for a real window's port
    @changes = 0
    @c = Tn3270::Gui::Controller.new(cfg, on_change: -> { @changes += 1 })
  end

  def teardown
    @c.shutdown
    @host.stop
    FileUtils.remove_entry(@dir)
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.05 until yield || Time.now > deadline
    assert yield, "condition not met"
  end

  def test_keystrokes_drive_the_host
    @c.connect("127.0.0.1:#{@host.port}")
    wait_until { @c.screen_text.include?("USER ID") }
    assert @c.connected?
    "user01".each_char { |ch| @c.type(ch) }
    @c.press(:enter)
    wait_until { @c.screen_text.include?("Signed on as USER01") }
    @c.type("1")
    @c.press(:enter)
    wait_until { @c.screen_text.include?("KEY TESTER") }
    @c.press(:pf20)
    wait_until { @c.screen_text.match?(/Last AID received:\s+PF20/) }
    @c.paste("pasted text")
    @c.press(:enter)
    wait_until { @c.screen_text.include?("Host saw:   pasted text") }
    assert @changes.positive?
    assert @c.history.size >= 3
    assert_includes @c.history.first.screen.text, "USER ID"
    assert_kind_of Time, @c.history.last.time
  end

  def test_connecting_state
    refute @c.connecting?
    @c.connect("127.0.0.1:#{@host.port}")
    assert @c.connecting? || @c.connected?
    wait_until { @c.connected? }
    refute @c.connecting?
    assert_equal "127.0.0.1", @c.last_target["host"]
  end
  def sign_on_to(option, screen_title)
    @c.connect("127.0.0.1:#{@host.port}")
    wait_until { @c.screen_text.include?("USER ID") }
    @c.type("user01")
    @c.press(:enter)
    wait_until { @c.screen_text.include?("MAIN MENU") }
    @c.type(option)
    @c.press(:enter)
    wait_until { @c.screen_text.include?(screen_title) }
  end

  def test_typeahead_and_response_time
    sign_on_to("4", "KEY TESTER (SLOW HOST)")
    @c.press(:enter) # the host takes 2 seconds to answer this
    sleep 0.3
    "ahead".each_char { |ch| @c.type(ch) }
    @c.press(:enter)
    wait_until { @c.typeahead_count.positive? }
    wait_until(8) { @c.screen_text.include?("Host saw:   ahead") }
    assert_equal 0, @c.typeahead_count
    assert_in_delta 2.0, @c.response_time, 0.6
  end

  def test_numeric_field_rejects_letters
    sign_on_to("1", "KEY TESTER")
    @c.move_to(12, 19) # first data position of the numeric field
    @c.type("a")
    wait_until { @c.message.to_s.include?("NUMERIC") }
    @c.type("42")
    wait_until { @c.screen_text.match?(/Numeric only: +42/) }
  end
  # Startup scripts run in their own process and attach through a script
  # port the tab opens for them (even with Allow Scripts to Attach off).
  def script_conn(file, body, name: "t")
    script = File.join(@dir, file)
    File.write(script, body)
    @c.instance_variable_get(:@config)["script_port"] = 3390 # clear of a real window's 3271
    Tn3270::Gui::Config::DEFAULT_CONNECTION.merge("name" => name, "port" => @host.port, "script" => script)
  end

  def test_startup_script_runs_once_connected
    conn = script_conn("logon.rb", <<~SCRIPT)
      wait_for_text("USER ID")
      fill("USER ID", connection["name"] == "t" ? "scripted" : "wrong")
      enter
      session.wait_for_text("MAIN MENU")
      status "Logged on by script"
    SCRIPT
    @c.connect(conn)
    wait_until(15) { @c.message == "Logged on by script" }
    wait_until { @c.screen_text.include?("Signed on as SCRIPTED") } # the window sees it at its next poll
    wait_until { !@c.startup_script_running? }
    assert_equal "Logged on by script", @c.message
  end

  def test_startup_script_knows_its_emulator_and_session
    conn = script_conn("who.rb", <<~SCRIPT, name: "Prod LPAR")
      status [emulator, session_name, ENV["TN3270_HOST_PORT"], ENV["TN3270_SCRIPT_PORT"]].join("|")
    SCRIPT
    @c.connect(conn)
    wait_until(15) { @c.message.to_s.start_with?("ruby3270|") }
    assert_equal "ruby3270|Prod LPAR|#{@host.port}|#{@c.attach_port}", @c.message
  end

  def test_startup_script_does_not_block_typing
    conn = script_conn("slow.rb", "wait_for_text('USER ID')
status 'waiting'
sleep 30
")
    @c.connect(conn)
    wait_until(15) { @c.message == "waiting" }
    assert @c.startup_script_running?
    @c.type("typed")
    wait_until { @c.screen_text.include?("typed") }
    @c.disconnect # its session is gone: the script stops too
    wait_until { !@c.startup_script_running? }
  end

  def test_startup_script_error_shows_in_status_bar
    conn = script_conn("bad.rb", "wait_for_text('USER ID')
no_such_method_here
")
    @c.connect(conn)
    wait_until(15) { @c.message.to_s.start_with?("Startup script failed") }
    assert_includes @c.message, "line 2"
  end

  def test_startup_script_in_another_language
    skip "Windows batch file" unless Gem.win_platform?
    conn = script_conn("who.cmd", "@echo %TN3270_EMULATOR% %TN3270_SESSION%
", name: "Batch")
    @c.connect(conn)
    wait_until(15) { @c.message == "ruby3270 Batch" }
  end

  # TLS to a host that doesn't use it: the handshake never finishes. The
  # controller gives up, says why, and stays usable.
  def test_hanging_tls_connect_gives_up_and_recovers
    @c.instance_variable_get(:@config)["connect_timeout"] = 2
    tls = Tn3270::Gui::Config::DEFAULT_CONNECTION.merge("port" => @host.port, "tls" => true)
    @c.connect(tls)
    wait_until(8) { @c.message.to_s.start_with?("Could not connect") } # no answer, or the handshake failed
    assert_includes @c.message, "untick Use TLS"
    refute @c.connecting?
    @c.connect("127.0.0.1:#{@host.port}") # a fresh engine took over
    wait_until { @c.screen_text.include?("USER ID") }
  end

  # Returns a lambda giving how many Enter keys the controller has sent from now on.
  def count_enter_presses
    n = 0
    @c.define_singleton_method(:send_key) { |key| n += 1 if key == :enter; super(key) }
    -> { n }
  end

  def test_auto_enter_loop
    @c.instance_variable_get(:@config)["auto_enter_seconds"] = 0.5
    sign_on_to("1", "KEY TESTER")
    presses = count_enter_presses
    @c.auto_enter = true
    assert @c.auto_enter?
    wait_until(6) { presses.call >= 3 } # Enter pressed again and again
    assert_match(/Last AID received:\s+ENTER/, @c.screen_text)
    @c.auto_enter = false
    sleep 1 # let a press already in flight finish
    count = presses.call
    sleep 1.5
    assert_equal count, presses.call, "kept pressing after being switched off"
  end

  def test_auto_enter_waits_for_a_slow_host_and_stops_on_disconnect
    @c.instance_variable_get(:@config)["auto_enter_seconds"] = 0.2
    sign_on_to("4", "KEY TESTER (SLOW HOST)") # answers each key after 2 seconds
    presses = count_enter_presses
    @c.auto_enter = true
    sleep 3
    assert_operator presses.call, :<=, 2, "pressed Enter before the host answered"
    @c.disconnect
    wait_until { !@c.auto_enter? }
    assert_includes @c.message, "not connected"
  end

# Two windows: the second one takes the next free port instead of the first one's.
def test_second_window_uses_the_next_free_port
  require "socket"
  server = TCPServer.new("127.0.0.1", 0) # stands in for the first window
  taken = server.addr[1]
    Thread.new { loop { server.accept.close } rescue IOError }
  cfg = Tn3270::Gui::Config.load(File.join(@dir, "second.yml"))
  cfg["allow_attach"] = true
  cfg["script_port"] = taken
  second = Tn3270::Gui::Controller.new(cfg, on_change: -> {})
  wait_until { second.attach_port } # the engine starts in the background
  refute_equal taken, second.attach_port
  second.connect("127.0.0.1:#{@host.port}")
  wait_until { second.screen_text.include?("USER ID") }
ensure
  second&.shutdown
  server&.close
end

  # Esc while the keyboard is locked: Reset at once (not queued behind the
  # lock), and the keys typed meanwhile are dropped, not sent later.
  def test_escape_resets_while_waiting_and_drops_typeahead
    sign_on_to("4", "KEY TESTER (SLOW HOST)") # answers each key after 2 seconds
    @c.press(:enter)
    wait_until { @c.waiting_for_host? }
    "abc".each_char { |ch| @c.type(ch) }
    wait_until { @c.typeahead_count == 3 }
    @c.press(:escape)
    wait_until { @c.typeahead_count.zero? && !@c.waiting_for_host? }
    assert_equal "Reset - 3 queued keys dropped", @c.message
    sleep 2.5 # the slow host answers the Enter
    refute_includes @c.screen_text, "Host saw:   abc"
    refute_match(/Last AID received:\s+CLEAR/, @c.screen_text)
  end

  def test_escape_unlocks_a_bad_entry
    sign_on_to("1", "KEY TESTER")
    @c.move_to(0, 5) # the title: protected
    @c.type("x")
    # The engine reports this as an ordinary lock; it's known by its message.
    wait_until { @c.operator_error? }
    assert_includes @c.message, "can't type there"
    assert @c.locked?
    @c.type("y") # keys typed after a bad entry are thrown away, as on a real terminal
    wait_until { @c.message.to_s.include?("discarded") }
    @c.press(:escape)
    wait_until { !@c.locked? && !@c.operator_error? }
    refute_match(/Last AID received:\s+CLEAR/, @c.screen_text) # it was a Reset, not a Clear
    # ...and the cursor moved off the title into a field you can type in.
    session = @c.instance_variable_get(:@session)
    wait_until do
      s = session.screen
      s.field_at(s.cursor_row, s.cursor_col)&.input?
    end
  end

  # Spelling fix: the word is swapped and the rest of the field moves to fit.
  def test_replace_word_in_a_field
    sign_on_to("1", "KEY TESTER") # "Typed text" is a 40-long field; its text starts at 8,17
    @c.type("teh job ran")
    wait_until { @c.screen_text.include?("teh job ran") }
    @c.replace_word(8, 17, "teh", "the")
    wait_until { @c.screen_text.lines[8].include?("the job ran") }
    @c.replace_word(8, 21, "job", "batch job")
    wait_until { @c.screen_text.lines[8].include?("the batch job ran") }
    @c.replace_word(8, 17, "teh", "the") # gone already: nothing changes
    wait_until { @c.message.to_s.include?("changed") }
    @c.replace_word(8, 17, "the", "x" * 30) # won't fit in the field
    wait_until { @c.message.to_s.include?("No room") }
    assert_includes @c.screen_text.lines[8], "the batch job ran"
  end

  def test_escape_is_clear_when_unlocked
    sign_on_to("1", "KEY TESTER")
    # The screen can arrive a moment before the keyboard unlocks (and Escape
    # on a locked keyboard is Reset, not Clear).
    wait_until { !@c.snapshot&.status&.keyboard_locked? }
    @c.press(:escape)
    wait_until { @c.screen_text.match?(/Last AID received:\s+CLEAR/) }
  end

  def test_shutdown_during_a_hanging_connect
    @c.connect(Tn3270::Gui::Config::DEFAULT_CONNECTION.merge("port" => @host.port, "tls" => true))
    sleep 0.5
    t = Time.now
    @c.shutdown # must not raise or wait for the connect
    assert_operator Time.now - t, :<, 5
    @c = Tn3270::Gui::Controller.new(Tn3270::Gui::Config.load(File.join(@dir, "cfg2.yml")), on_change: -> {})
  end
end
