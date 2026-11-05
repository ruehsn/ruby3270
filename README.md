# ruby3270

A 3270 mainframe terminal for the desktop, written in Ruby. Old green screens, new Ruby.

- A desktop window, built with [Glimmer DSL for LibUI](https://github.com/AndyObtiva/glimmer-dsl-libui)
- A Ruby API for scripting 3270 screens
- A fake host for trying it out without a mainframe

The 3270 protocol itself is handled by **s3270** (`ws3270.exe` on Windows) from the
[x3270 suite](https://x3270.bgp.nu). ruby3270 drives it and draws the screen.

## Features

- Screen scales with the window: the font is measured and the largest size that fits is picked on every resize
- VS Code style title bar (Windows): the menus sit inside the title bar, next to the icon, with the
  window buttons on the right. Turn it off under View > Menus in Title Bar; then the menus can
  either use a normal menu bar or open from a ☰ button in the status bar
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
- **Display font** (View > Font...): any installed font; monospaced fonts look best
- **Connections** (Session > Connections...): saved hosts with port, TLS, LU name and screen size
  (24x80, 32x80, 43x80, 27x132, 62x160 or custom), plus the path to the engine
- **Desktop shortcuts** (Windows): pressing Save in Session > Connections puts a shortcut with the app icon
  on your desktop, named after the session. Double-click it to open the emulator already connecting to that
  session. Renaming or deleting the session removes its old shortcut. Turn off with `desktop_shortcuts: false`
- **Copy a region**: drag across the screen to select a block, then Ctrl+C. With nothing selected,
  Ctrl+C copies the whole screen. A plain click moves the cursor
- **Type-ahead**: keys typed while the host is still answering (status bar shows X SYSTEM and
  TYPE-AHEAD n) are queued and sent in order once it answers. Reset cancels the wait
- **Find** (Ctrl+F or Edit > Find...): highlights matches on the screen as you type; Next / Previous move
  the cursor to them. "Search Screen History" lists matching lines in saved screens
- **Response time**: how long the host took to answer the last Enter/PF/PA key, in the status bar
- **Crosshair** (Ctrl+Shift+X or View > Crosshair): faint bands along the cursor's row and column
- **Numeric fields** accept only 0-9 . - (Keys > Numeric Fields: Digits Only)
- **CAPS button** in the status bar (or Edit > Caps Lock): types letters in upper case in this app only.
  The keyboard's Caps Lock is untouched, so other programs aren't affected
- App icon (`assets/tn3270.ico`, drawn by `script/make_icon.rb`)
- 3270 colors, intensified fields, hidden (password) fields, reverse video and underscore
- Optional underlines on input fields and an optional on-screen PF key bar
- Status line with host, keyboard lock (X SYSTEM), insert mode and cursor position
- Ruby API (`Tn3270::Session`) the window is built on, usable from your own scripts

## Requirements

| What | Version | Why |
|---|---|---|
| Ruby | 3.2 or newer (tested on 3.3 and 4.0) | Runs the app |
| x3270 engine: `ws3270.exe` (Windows) or `s3270` (Linux, macOS) | 4.x | Speaks the 3270 protocol to the host |
| Gems from the Gemfile: `glimmer-dsl-libui`, plus `win32ole` on Windows | installed by `bundle install` | The window, and desktop shortcuts |
| A 3270 host | any | Something to connect to. The built-in fake host works for trying it out |

No C compiler is needed: every gem is plain Ruby or comes prebuilt (LibUI ships as a ready-made library).
The scripting API and the tests use only Ruby's standard library plus the engine, so they work without the gems.

Runs on Windows, Linux and macOS. Windows gets a few extras: the VS Code style title bar, the window
icon and desktop shortcuts.

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

Full guide: [docs/API.md](docs/API.md).

```ruby
require "tn3270"

Tn3270::Session.open("myhost:3270") do |s|
  s.wait_for_text("USER ID")
  s.fill("USER ID", "USER01")      # finds the input field after a label
  s.fill("PASSWORD", ENV["PW"])
  s.enter
  s.wait_for_text("READY")
  s.pf(3)
  puts s.screen.text               # whole screen as text
  s.input_fields.each { |f| p [f.row, f.col, f.length, f.value] }
end
```

Main methods: `connect`, `disconnect`, `type`, `fill`, `move_to`, `press(:enter / :pf13 / :pa1 / :clear / :tab ...)`,
`pf(n)`, `pa(n)`, `wait_for_text`, `wait_for_input`, `screen`, `text`, `read(row, col, len)`,
`fields`, `field_at`, and `raw("AnyS3270Action()")`.

## Config

Saved in `~/.ruby3270.yml` (`%USERPROFILE%` on Windows). Only the keys you change are needed:

```yaml
engine: 'C:\Program Files\wc3270\ws3270.exe'
font: Consolas
history_size: 250         # screens kept in the screen history
desktop_shortcuts: true   # Save in Connections also makes a desktop shortcut
keys:                     # overrides of the default key bindings ("" unbinds)
  Ctrl+Q: reset
  Escape: ""
connections:
- name: Work mainframe
  host: mainframe.example.edu
  port: 23
  tls: false
  lu: ""
  rows: 27
  cols: 132
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
- **Keyboard layout.** LibUI reports keys unshifted, so shifted characters use a US layout table
  (`lib/tn3270/gui/keymap.rb`).
- **PF key bar.** Clicking a button takes keyboard focus. Click the screen to type again.

## Testing against a real MVS

Hercules with MVS 3.8j TK5 runs a free mainframe OS locally (prince-webdesign.nl/tk5).
Start it, then connect to `127.0.0.1:3270`.

## License

MIT. See [LICENSE](LICENSE). The x3270 suite (s3270 / ws3270.exe) is a separate project with its own license
and isn't included here.
