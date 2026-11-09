# Scripting 3270 screens from Ruby

`Tn3270::Session` lets a Ruby script do what a person at the emulator does: sign on, read the
screen, type into fields, press keys and wait for the host. The ruby3270 window is built on the
same API.

It needs the s3270 engine (`ws3270.exe` from wc3270 on Windows) but not the window gem (libui).

```ruby
require "tn3270"   # with the repo's lib/ on the load path: ruby -Ilib my_script.rb
```

To try anything here without a mainframe, run `ruby bin/fake_host` and connect to
`127.0.0.1:3270`. Sign on with any user ID.

- [Two ways in](#two-ways-in): start a new session, or attach to the one open in the window
- [A complete script](#a-complete-script)
- [Reference](#reference): connecting, typing, keys, waiting, reading, everyday helpers
- [Recipes](#recipes): common jobs, step by step
- [Startup scripts](#startup-scripts), [errors](#errors), [raw actions](#anything-else), [testing](#testing-scripts)

## Two ways in

**Start a new session.** The script starts its own engine, connects, and closes everything at the
end. Nothing shows on screen. Good for batch jobs.

```ruby
Tn3270::Session.open("mvs.example.com:23") do |s|
  s.logon("USER01", ENV["TSO_PW"], wait_for: "READY")
  puts s.text
end   # disconnects and stops the engine
```

**Attach to the session open in ruby3270.** The script works on the live screen in the window,
so you watch every step, and the session stays open when the script ends. Good for automating
the boring part of something you're doing by hand.

1. Nothing to set up: ruby3270 allows this by default, on port 3271.
   It only listens on this computer (127.0.0.1), but any program running as you can use it, so
   untick **Session > Allow Scripts to Attach** if you don't want that. The first session uses port
   3271; each other tab or window takes the next free one (3272, ...). Rest the pointer on the
   connection light in the status bar to see which, and use `Session.attach(port: 3272)` for that one. Change where the search starts with
   `script_port:` in the config file.
2. Connect as usual.
3. Run the script:

```ruby
Tn3270::Session.attach do |s|          # port: 3271, timeout: 10 by default
  puts s.line(0)                       # whatever the window shows right now
  s.submit("COMMAND ===>", "TSO PROFILE", wait_for: "READY")
end                                    # lets go; the window carries on
```

Avoid typing in the window while a script is working on it: both go to the same session.

See [examples/attach_to_session.rb](../examples/attach_to_session.rb) for a full example.

## A complete script

```ruby
require "tn3270"

Tn3270::Session.open("mvs.example.com:23", rows: 24, cols: 80) do |s|
  s.wait_for_text("USER ID")          # wait until the sign-on screen is up
  s.fill("USER ID", "USER01")         # type into the field after a label
  s.fill("PASSWORD", ENV["TSO_PW"])
  s.enter                             # press Enter and wait for the keyboard to unlock

  s.wait_for_text("READY")            # wait for the screen we expect
  s.submit("OPTION", "3.4", wait_for: "DATA SET LIST")   # fill + Enter + wait, in one call
  puts s.lines.grep(/USER01\./)       # every row mentioning USER01.
  s.pf(3)
end
```

[examples/common_calls.rb](../examples/common_calls.rb) walks through the calls below one at a time
against the fake host.

## Reference

Rows and columns are **0-based** everywhere: the top-left corner is row 0, column 0.

### Connecting

| Call | What it does |
| --- | --- |
| `Session.open(host, **opts) { \|s\| ... }` | Starts an engine, connects, runs the block, always closes. Without a block it returns the session; call `close` yourself. |
| `Session.attach(port: 3271) { \|s\| ... }` | Joins the session open in the ruby3270 window (see [Two ways in](#two-ways-in)). `close` lets go without disconnecting it. |
| `Session.new(**opts)` then `connect(host)` | Like `open`, in two steps. |
| `disconnect` / `close` | Drops the connection / also stops the engine (attached: just lets go). |
| `connected?`, `attached?`, `status` | Connection state, whether this is an attached session, and the latest status line. |

`host` is `"host"`, `"host:port"`, `"L:host:port"` for TLS, `"Y:L:host:port"` for TLS without
checking the host's certificate, or `"LU@host:port"` to ask for an LU.

Options for `open` / `new`:

| Option | Default | Meaning |
| --- | --- | --- |
| `rows:`, `cols:` | 62, 160 | Screen size to offer the host. Use 24 x 80 or 27 x 132 for hosts that only accept standard models. |
| `timeout:` | 10 | Default seconds for every wait. |
| `exe:` | found automatically | Path to the engine (otherwise `TN3270_ENGINE`, the PATH, or the wc3270 install folder). |
| `script_port:` | none | Let other scripts attach to this session, as the window does. |

`connect` waits until the host shows an input field. Pass `wait: false` to return at once.

### Typing and keys

| Call | What it does |
| --- | --- |
| `fill(where, text)` | Moves to a field, clears it, types `text`. `where` is a label on the screen (`"USER ID"`), a `[row, col]` pair, or a `Field`. Add `clear: false` to keep what's there. |
| `fill_form("USER ID" => "USER01", "PASSWORD" => pw)` | Several `fill`s at once. |
| `type(text)` | Types at the cursor. |
| `move_to(row, col)` | Moves the cursor. |
| `enter`, `pf(n)`, `pa(n)` | Sends Enter, PF1-24, PA1-3 and waits for the keyboard to unlock. |
| `press(key)` | Any key: `:enter :clear :pf13 :pa1 :tab :backtab :home :newline :reset :erase_eof :erase_input :backspace :delete :up :down :left :right :insert :attn :sysreq`. |

Enter, Clear, PF, PA, Attn and SysReq wait for the host by default. Pass `wait: false`
(`s.pf(3, wait: false)`) to send and move on. Most calls return the session, so they chain:
`s.fill("OPTION", "2").enter`.

### Waiting

Every wait takes `timeout:` (seconds) and raises `Tn3270::TimeoutError` when it runs out.

| Call | Waits until |
| --- | --- |
| `wait_for_text("READY")` | The text (or a Regexp) is on the screen. |
| `wait_for_text_gone("PLEASE WAIT")` | The text (or Regexp) has gone. |
| `wait_for_change(before)` | The screen differs from `before` (a `Screen` or text). Without an argument, from now. |
| `wait_until { \|scr\| ... }` | The block returns something truthy for a fresh screen; returns that value. Add `message:` for a clearer timeout error. |
| `wait_for_host` | The keyboard unlocks after an AID key (Enter and friends do this for you). |
| `wait_for_input` | The host shows an unprotected field. |

**Which wait?** `enter` already waits for the keyboard to unlock, but some hosts unlock before the
new screen is complete, or send it in pieces. When it matters, wait for something you expect on
the next screen: `s.press_and_wait(:enter, "READY")`. If you don't know what comes next, wait for
any change: `s.press_and_wait(:enter)`.

### Reading the screen

| On the session | Returns |
| --- | --- |
| `text` | The whole screen, rows joined with newlines. Hidden (password) fields read as blanks. |
| `line(row)` | One row, trailing blanks removed. |
| `lines` | Every row, as an array. |
| `read(row, col, length)` | A piece of one row, straight from the engine. |
| `value("LABEL")` | What's typed in the input field after a label, trimmed (`nil` if there's no such field). |
| `find("text")` | Where text appears: `[[row, col, length], ...]`. Add `match_case: true` to be exact. |
| `on_screen?(text_or_regexp)` | Whether it's on the screen now. |
| `cursor` | `[row, col]`. |
| `keyboard_locked?` | Whether the host has locked the keyboard. |
| `save_screen(path)` | Writes the screen text to a file and returns it. |
| `screen` | A snapshot (`Tn3270::Screen`) to read many things from at once. |

`s.screen` reads the whole screen once. Use it when you need several values from the same screen;
each session call above reads the screen afresh.

| On a `Screen` | Returns |
| --- | --- |
| `text`, `row_text(row)` | All rows / one row, as text. |
| `region_text(r1, c1, r2, c2)` | A rectangle of the screen, one line per row. |
| `include?(text)`, `find(text)` | Search, as above. |
| `fields`, `input_fields` | Every field / just the unprotected ones. |
| `field_after("LABEL")`, `field_at(row, col)` | One field, found by label or position. |
| `cell(row, col)` | One character with its `color`, `bright`, `hidden`, `highlight`. |
| `cursor_row`, `cursor_col`, `rows`, `cols` | Cursor position and screen size. |

A `Field` has `row`, `col` (where its data starts), `length`, `value`, `protected_field`,
`numeric`, `hidden`, `bright`, `modified`, `color`, and `input?`.

`s.status` has `connected?`, `host`, `keyboard_locked?`, `error?`, `rows`, `cols`,
`cursor_row`, `cursor_col`.

### Everyday helpers

Short-cuts for the steps nearly every script has.

| Call | Does |
| --- | --- |
| `logon(user, password, wait_for: "READY")` | Waits for the `USER ID` label, fills user and password, presses Enter, waits for `wait_for` (or any change). Other labels: `user_label:`, `password_label:`. Pass `nil` as the password to skip it. |
| `submit("OPTION", "3.4", wait_for: "DSLIST")` | Fills the field after a label, presses Enter (or `key:`), waits for text or any change. |
| `press_and_wait(:pf8, "BOTTOM OF DATA")` | Any key, then waits for text, or for any change when no text is given. |
| `type_snippet("=3.4{Enter}{wait:DSLIST}", answers: { ... })` | Types a [snippet](../README.md#snippets): text with `{Enter}`, `{PF3}`, `{wait:TEXT}`, `{ask:Question}` (answered from `answers:`), `{date}`, `{user}`... |
| `page_until("MY.DATASET", key: :pf8, max_pages: 50)` | Pages forward until the text shows up. Stops at the end of the list (a page that doesn't change). Returns true if found. |

## Recipes

### Sign on and check it worked

```ruby
s.logon("USER01", ENV.fetch("TSO_PW"), wait_for: /READY|ISPF/)
raise "sign-on failed: #{s.line(s.status.rows - 3)}" unless s.on_screen?(/READY|ISPF/)
```

Keep passwords out of scripts: read them from an environment variable (`ENV["TSO_PW"]`) or a
password manager.

### Run a command and read what comes back

```ruby
s.submit("COMMAND ===>", "TSO LISTCAT LEVEL(USER01)", wait_for: "READY")
names = s.lines.filter_map { |l| l[/USER01\.\S+/] }
```

### Wait for a slow host

```ruby
s.press_and_wait(:enter, "JOB COMPLETE", timeout: 120)   # up to two minutes
s.wait_for_text_gone("PLEASE WAIT", timeout: 60)
```

### Collect every row of a list that runs over several pages

```ruby
rows = []
loop do
  scr = s.screen
  rows.concat((4..scr.rows - 3).map { |r| scr.row_text(r).rstrip }.reject(&:empty?))
  break if scr.include?("BOTTOM OF DATA")

  s.press_and_wait(:pf8)
end
rows.uniq!
```

### Read a table by column position

```ruby
scr = s.screen
records = (5..20).map do |r|
  row = scr.row_text(r)
  { name: row[2, 44].strip, volume: row[47, 6].strip }   # columns as they appear on screen
end
```

Or take the block of text at once: `scr.region_text(5, 2, 20, 52)`.

### Act on whatever screen comes up

```ruby
case s.wait_until { |scr| %w[READY ISPF EXPIRED].find { |w| scr.include?(w) } }
when "EXPIRED" then s.submit("NEW PASSWORD", ENV["NEW_PW"])
when "ISPF"    then s.pf(3)
end
```

### Save evidence of each step

```ruby
s.save_screen("step1.txt")
s.raw("PrintText(html,file,step1.html)")   # an HTML picture of the screen, with colours
```

### Handle errors

```ruby
begin
  s.submit("OPTION", "3.4", wait_for: "DATA SET LIST", timeout: 20)
rescue Tn3270::TimeoutError
  s.save_screen("stuck.txt")      # what was on screen instead
  raise
end
```

`Tn3270::ActionError` usually means typing into a protected field, or the keyboard is locked
after an error (`X -f` in the status bar): `s.press(:reset)` clears that.

## Startup scripts

A saved connection can run a script each time it connects (Session > Connections > Startup
script), for example to sign on. It runs in its own process, attached to that tab's session
through its script port, so the window stays usable. A Ruby script has the session methods
available directly:

```ruby
logon(ENV.fetch("TN3270_USER"), ENV["TSO_PW"], wait_for: "READY")
status "Signed on to #{connection['name']}"   # a message in the status bar
```

`session` is the attached session, `connection` is the saved connection (a Hash: `"name"`,
`"host"`, `"port"`...), `emulator` is `"ruby3270"` and `session_name` the session's name. Lines
the script prints show in the status bar. If the script fails, the status bar shows the error and
its line number. Scripts in other languages get the same facts as environment variables
(`TN3270_EMULATOR`, `TN3270_SESSION`, `TN3270_SCRIPT_PORT`...; the full list is in the README).
See [examples/startup_script.rb](../examples/startup_script.rb).

## Errors

All errors inherit from `Tn3270::Error`:

- `Tn3270::TimeoutError`: a wait ran out of time.
- `Tn3270::ActionError`: the engine refused an action (for example typing into a protected field).
- `Tn3270::Error`: the engine couldn't start or stopped, or there was nothing to attach to.

## Anything else

`s.raw("Action(args)")` runs any [s3270 action](https://x3270.miraheze.org/wiki/S3270_actions)
directly and returns its output lines, for example `s.raw("PrintText(file,screen.txt)")`.

## Testing scripts

`Tn3270::FakeHost` is a small pretend mainframe (sign-on, menu, key tester with a numeric-only
field, color chart, ruler, and a slow key tester that takes 2 seconds to answer) for tests that
don't need a real host:

```ruby
require "tn3270/fake_host"
host = Tn3270::FakeHost.new(port: 0, log: nil).start   # port 0 = any free port
Tn3270::Session.open("127.0.0.1:#{host.port}") { |s| ... }
host.stop
```

See [test/helpers_test.rb](../test/helpers_test.rb) and [test/session_test.rb](../test/session_test.rb).
