# frozen_string_literal: true

# Scripting example. Start the fake host first (ruby bin/fake_host), then:
#   ruby examples/login_script.rb
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "tn3270"

Tn3270::Session.open("127.0.0.1:3270") do |s|
  s.wait_for_text("USER ID")
  s.fill("USER ID", "user01")
  s.fill("PASSWORD", "secret")
  s.enter
  s.wait_for_text("MAIN MENU")

  s.fill("OPTION", "1").enter
  s.wait_for_text("KEY TESTER")
  s.pf(15)
  puts s.screen.row_text(6).strip # => "Last AID received:  PF15"

  # Every field on the screen, with its position and attributes.
  s.input_fields.each do |f|
    puts format("row %2d col %3d len %3d %s%s", f.row, f.col, f.length,
                f.numeric ? "numeric " : "", f.hidden ? "hidden" : "")
  end

  s.pf(3)
  s.pf(3)
end
