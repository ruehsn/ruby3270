# frozen_string_literal: true

# Tests the GUI's keyboard mapping and background controller without
# opening a window (no Glimmer needed):  ruby -Ilib test/gui_logic_test.rb
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
    assert_equal [:key, :clear], K.translate(ev(ext_key: :escape))
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
    assert_equal "L:LU01@mvs.example.com:992", C.connect_string(c)
    assert_equal "h:23", C.connect_string(C.connection_from_string("h"))
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
end
