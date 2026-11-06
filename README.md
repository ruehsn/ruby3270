# ruby3270

A 3270 mainframe terminal for the desktop, written in Ruby. Old green screens, new Ruby.

- A desktop window, built on [libui](https://github.com/kojix2/LibUI) directly (one small gem, quick to start)
- A Ruby API for scripting 3270 screens
- A fake host for trying it out without a mainframe

The 3270 protocol itself is handled by **s3270** (`ws3270.exe` on Windows) from the
[x3270 suite](https://x3270.bgp.nu). ruby3270 drives it and draws the screen.

## Features

- Screen scales with the window: the font is measured and the largest size that fits is picked on every resize
- Quick to start and to draw: about 75 files load at startup (antivirus scanners check each one), and a
  full 62 x 160 screen redraws in about 5 ms
- VS Code style title bar (Windows): the menus sit inside the title bar, next to the icon, with the
  window buttons on the right (to use the normal Windows title bar instead, set `custom_title_bar: false`
  in the config file)
- Session menu lists your saved sessions, most recently used first; pick one to connect
- Status bar pinned to the bottom of the window, with a status light: green = connected,
  amber = connecting, grey = disconnected. Click it to disconnect, or to reconnect to the last host
- F1-F12 = PF1-12, Shift+F1-F12 = PF13-24, Ctrl+F1-F3 = PA1-3, Right Ctrl = New line
  (full list under Help > Keyboard)
- **Keyboard mapping** (Keys > Keyboard Mapping...): double-click an action and press any key combination,
  including a modifier on its own such as Right Ctrl
- **Screen history** (Ctrl+H or View > Screen History...): the last 250 screens, saved each time you press
  Enter/PF/PA/Clear, in a separate window with a large preview and a strip of thumbnails. Arrow keys or the
  arrow buttons move through them. Drag on the preview to select text (Ctrl+A selects all), then Ctrl+C or
  Copy to copy it, or Paste to Session to type it into the live screen at the cursor
- **Display font** (View > Font...): pick from the monospaced fonts installed on the PC, with a preview in
  the chosen font; the size always follows the window
- **Connections** (Session > Connections...): saved hosts with port, TLS, LU name and screen size
  (24x80, 32x80, 43x80, 27x132, 62x160 or custom), plus the path to the engine
- **TLS certificates**: by default the host's certificate isn't checked, so self-signed mainframe
  certificates just work. Tick "Verify the host's certificate" on a connection to check it. Unchecked, the
  connection is encrypted but can't tell an impostor from the real host, so turn it on for hosts
  reached over networks you don't trust
- **Startup script** (per connection): a Ruby file run each time that connection comes up, for example to
  sign on. See [Startup scripts](#startup-scripts)
- **Desktop shortcuts** (Windows): pressing Save in Session > Connections puts a shortcut with the app icon
  on your desktop, named after the session. Double-click it to open the emulator already connecting to that
  session. Renaming or deleting the session removes its old shortcut. Turn off with `desktop_shortcuts: false`
- **Copy a region**: drag across the screen to select a block, then Ctrl+C. With nothing selected,
  Ctrl+C copies the whole screen. A plain click moves the cursor. Right-click while something is
  selected copies it, clears the selection and moves the cursor to the pointer
- **Type-ahead**: keys typed while the host is still answering (status bar shows X SYSTEM and
  TYPE-AHEAD n) are queued and sent in order once it answers. Reset cancels the wait
- **Find** (Ctrl+F or Edit > Find...): highlights matches on the screen as you type; Next / Previous move
  the cursor to them. "Search Screen History" lists matching lines in saved screens
- **Response time**: how long the host took to answer the last Enter/PF/PA key, in the status bar
- **Crosshair** (Ctrl+Shift+X or View > Crosshair): faint bands along the cursor's row and column
- **Numeric fields** accept only 0-9 . - (Keys > Numeric Fields: Digits Only)
- **CAPS button** in the status bar (or Edit > Caps Lock): types letters in upper case in this app only.
  The keyboard's Caps Lock is untouched, so other programs aren't affected
- **ENTER button** in the status bar (or Keys > Auto Enter): presses Enter again 2 seconds after each answer
  from the host, over and over, to watch a job finish. Click it again to stop; it also stops by itself when
  the connection ends or the keyboard locks with an error. Change the pause with `auto_enter_seconds` in the
  config file
- **Tooltips**: rest the pointer on the connection light or the SNIP, ENTER, FK or CAPS buttons to see what they do
- **Snippets** (SNIP button, View > Snippets Sidebar, or Ctrl+Space): text and key sequences you type with a
  double-click, a hotkey or a few letters. See [Snippets](#snippets)
- App icon (`assets/tn3270.ico`, drawn by `script/make_icon.rb`)
- 3270 colors, intensified fields, hidden (password) fields, reverse video and underscore
- Optional underlines on input fields
- **Key bar** (FK button in the status bar, or View > Key Bar): PF1-PF24 plus Reset, Clear, Attn, New Line
  and SysReq as buttons. Clicking one gives the keyboard straight back to the screen
- **Window shape follows the screen** (Windows, View > Lock Window Shape to the Screen, on by default):
  dragging an edge keeps the window the shape of the mainframe screen, so the text fills it with no empty
  band. The window also reshapes when the screen size changes (another host, or the key bar shown)
- Status line with host, keyboard lock (X SYSTEM), insert mode and cursor position
- Ruby API (`Tn3270::Session`) the window is built on, usable from your own scripts

## Requirements

| What | Version | Why |
|---|---|---|
| Ruby | 3.2 or newer (tested on 3.3 and 4.0) | Runs the app |
| x3270 engine: `ws3270.exe` (Windows) or `s3270` (Linux, macOS) | 4.x | Speaks the 3270 protocol to the host |
| Gems from the Gemfile: `libui`, plus `win32ole` on Windows | installed by `bundle install` | The window, and desktop shortcuts |
| A 3270 host | any | Something to connect to. The built-in fake host works for trying it out |

No C compiler is needed: the `libui` gem ships the libui library ready-made and has no other gems behind
it. The scripting API and the tests use only Ruby's standard library plus the engine, so they work without
the gems.

Runs on Windows, Linux and macOS. Windows gets a few extras: the VS Code style title bar, the window
icon, desktop shortcuts and Right Ctrl as a key of its own.

## Setup

**Windows**

1. Install Ruby from [rubyinstaller.org](https://rubyinstaller.org). The DevKit isn't needed.
2. Install wc3270 from [x3270.bgp.nu](https://x3270.bgp.nu/download.html). ruby3270 finds `ws3270.exe` in
   the default install folder (`C:\Program Files\wc3270`) by itself. If you installed it elsewhere,
   add that folder to PATH or set `engine:` in the config file (below).
3. In this folder, run `bundle install`.

**Linux:** install Ruby and the `s3270` package (for example `sudo apt install ruby s3270`), then run `bundle install`.

**macOS:** `brew install ruby x3270`, then run `bundle install`.

## Run

```
ruby bin/fake_host              # terminal 1: pretend mainframe on port 3270
ruby bin/tn3270 127.0.0.1:3270  # terminal 2: the emulator
```

`ruby bin/tn3270 --session "Work mainframe"` opens a saved session by name (desktop shortcuts use this).

Sign on with any user ID. Option 1 is a key tester that shows which PF/PA key the
host received, option 2 is a color chart, and option 3 shows a ruler across all 160 columns.

## Scripting

Full guide, with a reference of every call and recipes for common jobs: [docs/API.md](docs/API.md).

A script can start its own session, or **attach to the one open in the window** (on by default; the
status bar shows `PORT 3271`) so you watch it work and the session stays open afterwards. Any program
on this computer can then drive the session; untick Session > Allow Scripts to Attach to stop that.

```ruby
require "tn3270"

Tn3270::Session.open("myhost:3270") do |s|       # or: Tn3270::Session.attach do |s|
  s.logon("USER01", ENV["PW"], wait_for: "READY") # fill USER ID + PASSWORD, Enter, wait
  s.submit("OPTION", "3.4", wait_for: "DSLIST")   # type a command, Enter, wait for the reply
  puts s.line(0)                                  # read a row
  puts s.value("COMMAND")                         # read an input field
  s.press_and_wait(:pf8)                          # any key, wait for the screen to change
  s.wait_for_text_gone("PLEASE WAIT")
  s.pf(3)
end
```

Main calls: `fill`, `fill_form`, `type`, `enter`, `pf(n)`, `pa(n)`, `press(key)`, `submit`, `logon`,
`wait_for_text`, `wait_for_text_gone`, `wait_for_change`, `wait_until { |screen| }`, `press_and_wait`,
`text`, `line`, `lines`, `value`, `find`, `on_screen?`, `cursor`, `screen`, `page_until`, `save_screen`
and `raw("AnyS3270Action()")`.

Examples: [examples/common_calls.rb](examples/common_calls.rb) (a tour of the calls, against the fake
host), [examples/attach_to_session.rb](examples/attach_to_session.rb) (drives the window's session),
[examples/login_script.rb](examples/login_script.rb).

## Snippets

A snippet is text to type, with keys and placeholders in braces, so one snippet can walk through
several screens:

```
=3.4{Enter}{wait:Data Set List Utility}
{ask:Data set level}{Enter}
```

- **Sidebar** (the SNIP button, View > Snippets Sidebar or Ctrl+Shift+S): search, double-click to type
  one, **New / Edit / Delete**, and **Files** to choose where snippets come from. Rest the pointer on a
  snippet to see its text.
- **Quick pick** (Ctrl+Space, or Edit > Snippets: Quick Pick): type a few letters, Enter types it.
  **Ctrl+N** (or the New button) makes a new snippet named after what you typed; **Ctrl+E** (or Edit) edits
  the chosen one. A snippet from a shared file you can't change opens as your own copy.
- **Hotkeys**: Ctrl+1 to Ctrl+9 type the first nine snippets in the sidebar list (change them in
  Keys > Keyboard Mapping).
- **From the screen**: select text, then Edit > New Snippet from Selection.

| In a snippet | Does |
|---|---|
| `{Enter}` `{PF1}`-`{PF24}` `{PA1}`-`{PA3}` `{Clear}` `{Attn}` `{SysReq}` | Presses the key and waits for the host to answer |
| `{Tab}` `{BackTab}` `{Home}` `{NewLine}` `{Reset}` `{EraseEOF}` `{EraseInput}` `{Up}` `{Down}`... | Presses the key |
| `{wait:READY}` | Waits until that text is on the screen (up to `snippet_wait_seconds`, 30 by default) |
| `{ask:Job name}` | Asks for a value when the snippet runs (each question once) |
| `{date}` `{date:%y%m%d}` `{time}` `{time:%H%M}` `{user}` `{clipboard}` | Fills in today's date, the time, your Windows user name, or the clipboard |
| a new line | Moves to the next input field, unless the line ended with a key |
| `{{` | A literal `{` |

**Your snippets and shared ones.** Your own snippets are in `~/.ruby3270-snippets.yml`. Under
**Files** you can add shared files or whole folders of `.yml` files, for example a team file on a
network drive, or create a new shared file. Snippets from files you can't write to are read-only.
Each file is a plain YAML list, easy to edit by hand or keep in git:

```yaml
- name: "SDSF: my jobs"
  text: "=S.ST{Enter}{wait:SDSF}PREFIX {user}*{Enter}"
```

[examples/snippets.yml](examples/snippets.yml) has examples for ISPF, TSO, SDSF and JCL, plus a few for
the fake host.

## Startup scripts

A connection can run a Ruby file each time it comes up: pick it under Session > Connections > Startup
script. It runs against the live session, so you see every step, and the keys you type meanwhile wait
until it ends. Session methods can be called directly ([examples/startup_script.rb](examples/startup_script.rb)):

```ruby
wait_for_text("USER ID")
fill("USER ID", "USER01")
fill("PASSWORD", ENV["TSO_PW"])   # keep passwords out of the file
enter
wait_for_text("READY")
status "Signed on to #{connection['name']}"   # shown in the status bar
```

If the script fails, the status bar shows the error and its line number.

## Config

Saved in `~/.ruby3270.yml` (`%USERPROFILE%` on Windows). Only the keys you change are needed:

```yaml
engine: 'C:\Program Files\wc3270\ws3270.exe'
font: Consolas
history_size: 250         # screens kept in the screen history
desktop_shortcuts: true   # Save in Connections also makes a desktop shortcut
snippet_files:            # shared snippet files or folders (yours: ~/.ruby3270-snippets.yml)
- '\\server\team\3270-snippets.yml'
lock_ratio: true          # keep the window the shape of the screen while resizing
keys:                     # overrides of the default key bindings ("" unbinds)
  Ctrl+Q: reset
  Escape: ""
connections:
- name: Work mainframe
  host: mainframe.example.edu
  port: 23
  tls: true
  verify_cert: false      # true: check the host's TLS certificate
  lu: ""
  rows: 27
  cols: 132
  script: 'C:\scripts\logon.rb'   # startup script ("" = none)
```

The menus write all of these for you; you rarely need to edit the file. A plain `ruby bin/tn3270 host:port`
uses `rows`/`cols` (default 62 x 160).

## Tests

```
ruby -Ilib test/session_test.rb      # Ruby API against the fake host
ruby -Ilib test/gui_logic_test.rb    # key mapping and the GUI's background worker
```

These need s3270 but not the window gems.

## Things to know

- **Screen size and the real host.** 160 x 62 is not a standard 3270 model. The emulator offers it
  as a dynamic size, and the host's logmode has to accept that. If the host only allows a fixed
  model, pick 27 x 132 (Model 5) or 24 x 80 for that connection in Session > Connections.
- **Keyboard layout.** libui reports keys unshifted, so shifted characters use a US layout table
  (`lib/tn3270/gui/keymap.rb`).

## Testing against a real MVS

Hercules with MVS 3.8j TK5 runs a free mainframe OS locally (prince-webdesign.nl/tk5).
Start it, then connect to `127.0.0.1:3270`.

## License

MIT. See [LICENSE](LICENSE). The x3270 suite (s3270 / ws3270.exe) is a separate project with its own license
and isn't included here.
