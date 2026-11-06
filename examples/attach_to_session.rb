# frozen_string_literal: true

# Drives the session that is already open in the ruby3270 window.
#
#   1. Start ruby3270 (Session > Allow Scripts to Attach is on by default; the status bar shows PORT 3271).
#   2. Connect to the fake host (ruby bin/fake_host) or your mainframe.
#   3. ruby examples/attach_to_session.rb
#
# You watch every step happen in the window. When the script ends, the session
# stays open, right where the script left it.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "tn3270"

Tn3270::Session.attach(port: 3271, timeout: 15) do |s|
  # ---- read the screen ---------------------------------------------------------
  puts "Screen is #{s.status.rows} x #{s.status.cols}, cursor at #{s.cursor.inspect}"
  puts "Top line:  #{s.line(0).strip}"
  puts "Fields to type in: #{s.input_fields.size}"

  # ---- sign on, if the sign-on screen is showing ---------------------------------
  if s.on_screen?("USER ID")
    s.fill("USER ID", ENV.fetch("TN3270_USER", "user01"))   # type into the field after a label
    s.fill("PASSWORD", ENV.fetch("TN3270_PW", "")) if s.on_screen?("PASSWORD")
    s.enter                                                   # Enter, then wait for the keyboard to unlock
    s.wait_for_text("MAIN MENU")                              # wait for the screen we expect
  end

  # ---- enter data and wait for the screen to come back ------------------------------
  s.submit("OPTION", "1", wait_for: "KEY TESTER")            # fill + Enter + wait, in one call
  s.fill("Typed text", "hello from Ruby")
  s.press_and_wait(:enter, "Host saw:   hello from Ruby")    # any key, then wait for text
  puts s.line(10).strip

  # ---- a key without waiting, then wait on our own terms ----------------------------
  before = s.screen
  s.pf(15, wait: false)
  s.wait_for_change(before)                                   # any change at all
  puts s.lines.grep(/Last AID/).first.strip

  # ---- back to the menu --------------------------------------------------------
  s.pf(3)
  s.wait_for_text_gone("KEY TESTER")
end

puts "Detached; the session is still open in the window."
