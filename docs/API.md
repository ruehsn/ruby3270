# Scripting 3270 screens from Ruby

`Tn3270::Session` lets a Ruby script sign on to a mainframe, read the screen and type into it,
the same way a person at the emulator would. The desktop window is built on this API.

It needs the s3270 engine (`ws3270.exe` from wc3270 on Windows) but not the window gems (Glimmer DSL for LibUI).

## A complete script

```ruby
require "tn3270"   # with the repo's lib/ on the load path: ruby -Ilib my_script.rb

Tn3270::Session.open("mvs.example.com:23") do |s|
  s.wait_for_text("USER ID")          # wait until the sign-on screen is up
  s.fill("USER ID", "USER01")         # type into the field after a label
  s.fill("PASSWORD", ENV["TSO_PW"])
  s.enter                             # press Enter and wait for the host to answer

  s.wait_for_text("READY")
  s.fill("OPTION", "3.4").enter       # fill and press are chainable
  puts s.screen.text                  # the whole screen as plain text
  s.pf(3)
end                                   # disconnects and stops the engine
```

To try it without a mainframe, run `ruby bin/fake_host` and connect to `127.0.0.1:3270`.

## Connecting

| Call | What it does |
| --- | --- |
| `Session.open(host, **opts) { \|s\| ... }` | Connect, run the block, always close. Without a block it returns the session; call `close` yourself. |
| `Session.new(**opts)` then `connect(host)` | Same, in two steps. |
| `disconnect` / `close` | Drop the connection / also stop the engine. |
| `connected?`, `status` | Connection state and the latest status line (see below). |

`host` is `"host"`, `"host:port"`, `"L:host:port"` for TLS, or `"LU@host:port"` to ask for an LU.

Options: `rows:`/`cols:` (default 62 x 160; use 24 x 80 or 27 x 132 for hosts that only accept
standard models), `timeout:` (default seconds for every wait, 10), `exe:` (engine path; otherwise
`TN3270_ENGINE` or the PATH).

`connect` waits until the host shows an input field. Pass `wait: false` to return at once.

## Typing and keys

| Call | What it does |
| --- | --- |
| `fill(where, text)` | Moves to a field, clears it, types `text`. `where` is a label on the screen (`"USER ID"`), a `[row, col]` pair, or a `Field`. Add `clear: false` to keep what is there. |
| `type(text)` | Types at the cursor. |
| `move_to(row, col)` | Moves the cursor. |
| `enter`, `pf(n)`, `pa(n)` | Sends Enter, PF1-24, PA1-3 and waits for the host to answer (keyboard unlocks). |
| `press(key)` | Any key: `:enter :clear :pf13 :pa1 :tab :backtab :home :newline :reset :erase_eof :erase_input :backspace :delete :up :down :left :right :insert :attn :sysreq`. |

Enter, Clear, PF, PA, Attn and SysReq wait for the host by default. Pass `wait: false`
(`s.pf(3, wait: false)`) to send and move on.

## Waiting

| Call | Waits until |
| --- | --- |
| `wait_for_text("READY")` | The text (or a Regexp) is on the screen. |
| `wait_for_input` | The host shows an unprotected field. |
| `wait_for_host` | The keyboard unlocks after an AID key. |

Each takes `timeout:` and raises `Tn3270::TimeoutError` when it runs out.

## Reading the screen

`s.screen` takes a fresh snapshot (`Tn3270::Screen`). Rows and columns are **0-based**.

| On a `Screen` | Returns |
| --- | --- |
| `text` | All rows joined with newlines. Hidden (password) fields read as blanks. |
| `row_text(row)` | One row. |
| `region_text(r1, c1, r2, c2)` | A rectangle of the screen, one line per row. |
| `include?(text)` | Whether the text is anywhere on the screen. |
| `fields`, `input_fields` | Every field / just the unprotected ones. |
| `field_after("LABEL")`, `field_at(row, col)` | One field, found by label or position. |
| `cell(row, col)` | One character with its `color`, `bright`, `hidden`, `highlight`. |
| `cursor_row`, `cursor_col`, `rows`, `cols` | Cursor position and screen size. |

Shortcuts on the session: `s.text`, `s.include?`, `s.fields`, `s.input_fields`, `s.field_at`,
and `s.read(row, col, length)` for a piece of the screen without taking a snapshot.

A `Field` has `row`, `col` (where its data starts), `length`, `value`, `protected_field`,
`numeric`, `hidden`, `bright`, `modified`, `color`, and `input?`.

`s.status` has `connected?`, `host`, `keyboard_locked?`, `error?`, `rows`, `cols`,
`cursor_row`, `cursor_col`.

## Errors

All errors inherit from `Tn3270::Error`:

- `Tn3270::TimeoutError`: a wait ran out of time.
- `Tn3270::ActionError`: the engine refused an action (for example typing into a protected field).
- `Tn3270::Error`: the engine could not start or stopped.

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

See [test/session_test.rb](../test/session_test.rb) and
[examples/login_script.rb](../examples/login_script.rb) for more.
