# Startup script: runs inside the emulator each time its connection comes up.
# Pick it in Session > Connections > Startup script.
#
# It runs against the live session, so the window shows every step. Keys you
# type while it runs wait until it ends. Available here:
#   Session methods, called directly: wait_for_text, fill, type, enter, pf(n),
#     pa(n), press(:clear), move_to, text, read, input_fields... (docs/API.md)
#   session     the same session, if you prefer session.fill(...)
#   connection  the saved connection: connection["name"], connection["host"], ...
#   status "…"  shows a message in the status bar
#
# This one signs on to the fake host (ruby bin/fake_host). Keep passwords out
# of the file: read them from an environment variable instead.

wait_for_text("USER ID")
fill("USER ID", ENV.fetch("TN3270_USER", "user01"))
fill("PASSWORD", ENV.fetch("TN3270_PW", "")) if text.include?("PASSWORD")
enter
wait_for_text("MAIN MENU")

status "Signed on to #{connection['name']}"
