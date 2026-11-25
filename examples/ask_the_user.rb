# Name: Ask, choose and show (example)
# Asks you for a user ID, lets you pick a menu option, then shows what it found.
# Shows how a script talks to you without typing into the 3270 screen.

# How to run it:
#   - from the window: Snippets sidebar > Files > Add Script Folder, pick the
#     examples folder, then double-click "Ask, choose and show (example)"
#   - or on its own, against the tab on port 3271:  ruby -Ilib examples/ask_the_user.rb
#
# Every question opens a small window of its own over the ruby3270 window; the
# 3270 screen never gets the typing. Cancel gives nil. Stop Script (in the
# question, the STOP button in the status bar, or Session > Stop Scripts) ends
# the script: the call raises Tn3270::ScriptStopped.
#
# Works against the fake host: ruby bin/fake_host, then connect to 127.0.0.1:3270.
require "tn3270"

# From a script folder (or as a startup script) `session` is already attached;
# on its own, attach to the tab whose port is in TN3270_SCRIPT_PORT (or 3271).
s = defined?(session) ? session : Tn3270::Session.attach(port: Integer(ENV.fetch("TN3270_SCRIPT_PORT", "3271")))

# ---- a line of text ----------------------------------------------------------------
if s.on_screen?("USER ID")
  user = s.ask("User ID to sign on with?", default: ENV.fetch("USERNAME", "user01"), title: "Sign on")
  if user.nil? || user.strip.empty?
    s.notify("Nothing done: no user ID given") # a message in the tab's status bar
    exit
  end

  s.fill("USER ID", user)
  # secret: true hides what you type, for a password:
  #   s.fill("PASSWORD", s.ask("Password?", secret: true)) if s.on_screen?("PASSWORD")
  s.enter
  s.wait_for_text("MAIN MENU")
end

# ---- one of a list -------------------------------------------------------------------
unless s.on_screen?("OPTION ===>")
  s.notify("Go to the fake host's main menu first, then run this again")
  exit
end
options = { "Key tester" => "1", "Color chart" => "2", "Wide screen" => "3" }
# other: adds a choice with a text box, here for typing a menu number yourself.
pick = s.choose("Which screen should I open?", options.keys, default: "Color chart", title: "Menu",
                other: "Option number:")
exit unless pick # Cancel

s.submit("OPTION", options.fetch(pick, pick)) # a listed screen, or the number typed under Other
s.notify("Opened #{pick}")

# ---- text in a window of its own -------------------------------------------------------
# Showing again with the same title updates that window, so a long job can show
# its progress there. wait: true waits until you close it.
report = s.lines.reject(&:empty?).first(12)
s.show("#{pick}, the first lines on screen:\n\n#{report.join("\n")}", title: "What the script saw")
