# frozen_string_literal: true

# Runs against the built-in FakeHost, so no mainframe is needed:
#   ruby -Ilib test/session_test.rb
require "minitest/autorun"
require "tn3270"
require "tn3270/fake_host"

class SessionTest < Minitest::Test
  def setup
    @host = Tn3270::FakeHost.new(port: 0, log: nil).start
    @s = Tn3270::Session.open("127.0.0.1:#{@host.port}", timeout: 5)
  end

  def teardown
    @s&.close
    @host&.stop
  end

  def test_negotiates_full_screen_size
    @s.wait_for_text("SIGN ON")
    st = @s.status
    assert_equal [62, 160], [st.rows, st.cols]
    assert_includes @s.screen.row_text(0), "62x160"
  end

  def test_reads_fields_and_colors
    scr = @s.wait_for_text("USER ID").screen
    assert_equal 2, scr.input_fields.size
    pw = scr.field_after("PASSWORD")
    assert pw.hidden
    assert_equal :turquoise, scr.cell(0, 2).color
    assert scr.cell(0, 2).bright
  end

  def test_login_and_menu
    @s.wait_for_text("USER ID")
    @s.fill("USER ID", "user01")
    @s.fill("PASSWORD", "secret")
    @s.enter
    @s.wait_for_text("MAIN MENU")
    assert @s.include?("Signed on as USER01")
    refute @s.include?("secret")
  end

  def test_pf_keys_reach_the_host
    login
    @s.fill("OPTION", "1").enter
    @s.wait_for_text("KEY TESTER")
    [[:pf5, "PF5"], [:pf13, "PF13"], [:pf24, "PF24"], [:pa1, "PA1"], [:clear, "CLEAR"]].each do |key, name|
      @s.press(key)
      @s.wait_for_text(/Last AID received:\s+#{name}\b/)
    end
    @s.fill("Typed text", "hello 3270").enter
    @s.wait_for_text("Host saw:   hello 3270")
  end

  # Typing where you can't: the error says why, but not what was typed
  # (it may be a password, and messages end up in status bars and logs).
  def test_action_error_keeps_typed_text_out_of_its_message
    @s.wait_for_text("USER ID")
    @s.move_to(1, 1)
    err = assert_raises(Tn3270::ActionError) { @s.type("hunter2): tail") }
    assert_match(/\AString\(\.\.\.\): .*Operator error/i, err.message)
    refute_includes err.message, "hunter2"
    refute_includes err.message, "tail"
    assert_includes err.action, "hunter2"
    assert_match(/Operator error/i, err.detail)
    @s.press(:reset)
  end

  def test_action_error_names_other_actions_in_full
    err = assert_raises(Tn3270::ActionError) { @s.raw("Bogus(1)") }
    assert_equal ["Bogus(1)", "Bogus(1): #{err.detail}"], [err.action, err.message]
    assert_equal ["plain", "plain", nil], Tn3270::ActionError.new("plain").then { |e| [e.message, e.detail, e.action] }
  end

  def test_pf3_goes_back
    login
    @s.pf(3)
    @s.wait_for_text("SIGN ON")
  end

  def test_full_width_ruler
    login
    ruler = @s.screen.row_text(62 - 5)
    assert_equal 160, ruler.size
    assert_equal "5", ruler[150] # column 150 numbered as "5" (150 / 10 % 10)
  end

  private

  def login
    @s.wait_for_text("USER ID")
    @s.fill("USER ID", "user01").enter
    @s.wait_for_text("MAIN MENU")
  end
end
