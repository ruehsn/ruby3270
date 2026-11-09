# frozen_string_literal: true

# Runs a Ruby startup script in its own process, attached to the session it
# belongs to (see StartupScript). ruby3270 starts it as:
#   ruby -I lib lib/tn3270/gui/startup_runner.rb SCRIPT
require "json"
require "tn3270"
require "tn3270/gui/startup_script"

$stdout.sync = true
path = ARGV.fetch(0)
connection = JSON.parse(ENV.fetch("RUBY3270_CONNECTION", "{}"))
failed = Tn3270::Gui::StartupScript::FAILED
begin
  session = Tn3270::Session.attach(host: ENV.fetch("TN3270_SCRIPT_HOST", "127.0.0.1"),
                                   port: Integer(ENV.fetch("TN3270_SCRIPT_PORT")))
rescue StandardError => e
  warn "#{failed}: couldn't attach to the session (#{e.message})"
  exit 1
end
ok = Tn3270::Gui::StartupScript::Context.run(path, session, connection)
session.close
exit(ok ? 0 : 1)
