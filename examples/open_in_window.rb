# frozen_string_literal: true

# Opens a new tab in the running ruby3270 window, signs on there while you
# watch, and leaves the tab open for you.
#   1. Start ruby3270 (ruby bin/tn3270).
#   2. ruby -Ilib examples/open_in_window.rb
# To try it without a mainframe: ruby bin/fake_host, then use "127.0.0.1:3270".
require "tn3270"

host = ARGV.fetch(0, "127.0.0.1:3270") # a host, or the name of a saved session (use session: below)

Tn3270::Session.open_in_window(host) do |s|
  s.logon("USER01", ENV.fetch("TSO_PW", "secret"), wait_for: "MAIN MENU")
  puts s.line(0)
end # lets go; the tab stays open
