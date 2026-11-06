# frozen_string_literal: true

# The everyday helpers and Session.attach, against the built-in FakeHost:
#   ruby -Ilib test/helpers_test.rb
require "minitest/autorun"
require "tmpdir"
require "tn3270"
require "tn3270/fake_host"

class HelpersTest < Minitest::Test
  def setup
    @host = Tn3270::FakeHost.new(port: 0, log: nil).start
    @s = Tn3270::Session.open("127.0.0.1:#{@host.port}", rows: 24, cols: 80, timeout: 5)
    @s.wait_for_text("USER ID")
  end

  def teardown
    @s&.close
    @host&.stop
  end

  def test_logon_and_submit
    @s.logon("user01", "secret", wait_for: "MAIN MENU")
    assert @s.on_screen?("Signed on as USER01")
    @s.submit("OPTION", "1", wait_for: "KEY TESTER")
    assert @s.on_screen?(/KEY\s+TESTER/)
  end

  def test_fill_form_and_value
    @s.fill_form("USER ID" => "user01", "PASSWORD" => "pw")
    assert_equal "user01", @s.value("USER ID")
    assert_nil @s.value("NO SUCH LABEL")
  end

  def test_press_and_wait_for_change
    @s.fill("USER ID", "user01")
    @s.press_and_wait(:enter) # no text given: waits for the screen to change
    assert @s.on_screen?("MAIN MENU")
  end

  def test_wait_until_and_text_gone
    @s.logon("user01", nil, wait_for: "MAIN MENU")
    row = @s.wait_until { |scr| scr.find("OPTION").first&.first }
    assert_equal 10, row
    @s.pf(3)
    @s.wait_for_text_gone("MAIN MENU")
    assert @s.on_screen?("SIGN ON")
  end

  def test_wait_until_times_out
    err = assert_raises(Tn3270::TimeoutError) { @s.wait_until(timeout: 0.3, message: "a unicorn") { false } }
    assert_includes err.message, "a unicorn"
  end

  def test_reading_helpers
    assert_includes @s.line(7), "USER ID  ===>"
    assert_equal 24, @s.lines.size
    assert_equal [[7, 5, 7]], @s.find("USER ID", match_case: true)
    assert_equal 2, @s.find("user id").size # any case: also "user ID" in the welcome line
    assert_equal [7, @s.screen.field_after("USER ID").col], @s.cursor # the cursor waits in the first input field
    refute @s.keyboard_locked?
    Dir.mktmpdir do |dir|
      path = File.join(dir, "screen.txt")
      @s.save_screen(path)
      assert_includes File.read(path), "SIGN ON"
    end
  end

  def test_page_until_stops_at_the_end
    # The sign-on screen doesn't scroll, so PF8 leaves it unchanged: page_until gives up.
    refute @s.page_until("NOT THERE", max_pages: 3)
    assert @s.page_until("USER ID")
  end
end

class AttachTest < Minitest::Test
  PORT = 43_299

  def setup
    @host = Tn3270::FakeHost.new(port: 0, log: nil).start
    # The "existing session": like the ruby3270 window with Allow Scripts to Attach on.
    @owner = Tn3270::Session.open("127.0.0.1:#{@host.port}", rows: 24, cols: 80, timeout: 5, script_port: PORT)
    @owner.wait_for_text("USER ID")
  end

  def teardown
    @owner&.close
    @host&.stop
  end

  def test_attach_works_on_the_live_screen
    Tn3270::Session.attach(port: PORT, timeout: 5) do |s|
      assert s.attached?
      assert_equal [24, 80], [s.status.rows, s.status.cols]
      s.logon("user01", nil, wait_for: "MAIN MENU")
    end
    # The owner sees what the attached script did, and is still connected.
    assert @owner.on_screen?("Signed on as USER01")
    assert @owner.connected?
  end

# Somebody else (another ruby3270 window) already listens on the port: an
# engine must not connect to it and think it is its own.
def test_engine_never_talks_to_someone_elses_port
  require "socket"
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1]
  accepted = 0
  Thread.new { loop { server.accept.close; accepted += 1 } }
  err = assert_raises(Tn3270::Error) { Tn3270::Engine.new(rows: 24, cols: 80, script_port: port) }
  assert_includes err.message, "already in use"
  assert_operator Tn3270::Engine.free_port(port), :>, port
  assert_operator accepted, :<=, 2 # only our own "is it free?" probes
ensure
  server&.close
end

  def test_attach_with_nothing_there
    err = assert_raises(Tn3270::Error) { Tn3270::Session.attach(port: PORT + 1) }
    assert_includes err.message, "Allow Scripts to Attach"
  end
end
