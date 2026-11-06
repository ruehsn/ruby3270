# frozen_string_literal: true

# A tour of the calls most scripts need, one small step each.
# Start the fake host first (ruby bin/fake_host), then:
#   ruby examples/common_calls.rb
#
# To run the same steps against the session open in the ruby3270 window,
# replace Session.open(...) with Session.attach (see examples/attach_to_session.rb).
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "tn3270"

Tn3270::Session.open("127.0.0.1:3270", rows: 24, cols: 80, timeout: 10) do |s|
  # Sign on: waits for the USER ID label, fills both fields, presses Enter,
  # and waits for the next screen.
  s.logon("user01", "secret", wait_for: "MAIN MENU")

  # Is something on the screen right now? (text or a Regexp)
  puts "Signed on" if s.on_screen?(/Signed on as \w+/)

  # Read: one row, every row, a piece of a row, where some text is.
  puts s.line(0)                                   # row 0, trailing blanks removed
  puts s.lines.size                                # 24
  puts s.read(3, 4, 20)                            # row 3, column 4, 20 characters
  p s.find("OPTION")                               # [[row, col, length]], 0-based

  # Enter a command: fill the field after a label, press Enter, wait for text.
  s.submit("OPTION", "1", wait_for: "KEY TESTER")

  # Several fields at once, then read back what a field holds.
  s.fill_form("Typed text" => "abc", "Numeric only" => "42")
  puts "Typed text field holds: #{s.value('Typed text').inspect}"
  s.enter
  puts "Host saw: #{s.line(10)[16..].strip}"

  # Any key, then wait for some text (or, with no text, for the screen to change).
  s.press_and_wait(:pf20, /Last AID received:\s+PF20/)

  # Wait for your own condition; the block gets a fresh screen each time.
  aid = s.wait_until(message: "an AID name") { |scr| scr.row_text(6)[/PF\d+/] }
  puts "Host saw key #{aid}"

  # Keep a copy of the screen.
  s.save_screen("screen.txt")

  # Page through a long list until something shows up (PF8 by default).
  # The key tester doesn't scroll, so this stops at once and returns false.
  puts "found" if s.page_until("NOT IN THIS LIST", max_pages: 3)

  # Back out.
  s.pf(3)
  s.wait_for_text_gone("KEY TESTER")
  puts "Back at: #{s.line(0).strip}"
end
