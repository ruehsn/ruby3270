# Session tabs, settings sharing and faster keys (2026-11-08)

## Summary
ruby3270 went from one session per window to browser-style session tabs: tabs can be reordered,
dragged out into their own window and dropped onto another window, with the session staying
connected. The whole app now runs as one process holding every window. The quick picker
(Ctrl+Space) can also switch on/off settings. Settings can be exported, imported, and handed
out to a team with a `welcome.yml`. Spell checking of long input fields came in, and new tabs,
engine start and key echo got much faster. The status bar no longer shows the script port,
and the README now has a screenshot and a GIF, built without touching the desktop.

## Decisions

### One process for every window, with a single-instance handoff
- **What:** `Program` owns the shared menus, the window list and the snippet library. A second
  launch (e.g. a desktop shortcut) sends its session to the running copy over a local TCP port
  and exits; the port and a secret token are in `~/.ruby3270.instance`.
- **Why:** a live s3270 connection can't move between processes, so dragging a tab from one
  window to another needs one process. The token is per user, so on a terminal server one user
  can't open sessions in another user's app. `single_instance: false` turns it off.
- **Where:** [program.rb](../../lib/tn3270/gui/program.rb), [instance.rb](../../lib/tn3270/gui/instance.rb)
  (`Instance.forward`, `Instance#requests`).

### Menus are global; commands go to the window that was clicked
- **What:** libui menus exist once per process. Each menu callback gets the window it was
  clicked in, and `Program#window_for` sends the command there. View options run in every
  window (`for_all`).
- **Why:** libui offers no per-window menus.
- **Where:** `Program#item`, `#check_item`, `#build_menus`.

### Tab dragging runs on a timer, not in mouse events
- **What:** a press on a tab starts a drag that the timer follows by reading the cursor and
  button state straight from Windows (`GetCursorPos` / `GetAsyncKeyState`), moving through the
  modes `:press`, `:strip` and `:float`. Windows are only created or destroyed on the timer.
- **Why:** the drag keeps working outside the app's windows, and no window is destroyed
  inside its own mouse callback.
- **Where:** `Program#begin_tab_drag`, `#drag_tick`, `#detach`, `#drag_floating`;
  `TerminalWindow#drag_tab`; layout maths in `TabStrip` ([tab.rb](../../lib/tn3270/gui/tab.rb)).

### A tab owns its session
- **What:** `Tab` holds the controller (engine plus worker thread) and the view state for that
  session (selection, number, custom name). Moving a tab moves this object.
- **Why:** the connection carries on unchanged when a tab changes window.
- **Where:** [tab.rb](../../lib/tn3270/gui/tab.rb), `TerminalWindow#select_tab`, `#add_tab`, `#remove_tab`.

### Tab names: the session's name, numbered, renamable
- **What:** a tab shows its saved session's name, even when it was opened as a plain
  `host:port` that matches a saved session. Several tabs on one session are numbered
  `PROD`, `PROD (2)`... Each keeps its number while it stays on that session, and a new tab
  takes the lowest free number. A renamed tab shows its own name and gives up its number.
- **Why:** the user asked for no IP addresses in titles, and for duplicate sessions to be
  numbered. Keeping numbers stable stops names shifting when another tab closes.
- **Where:** `Tab#name`, `#title`, `Tab.number_all` (called from `Program#pump`),
  `TerminalWindow#rename_tab`, `#duplicate_tab`, `#duplicate_session`.

### Engines start on the tab's worker, and ports are checked by binding
- **What:** `Controller.new` no longer starts ws3270; its worker thread does
  (`Controller#start_engine`). `Engine.port_in_use?` now tries to bind the port instead of
  connecting to it, and `start_with_port` waits for the engine to take its port before
  connecting.
- **Why:** a new tab froze the window for about 1.7 s. On Windows a refused local connect takes
  about 2 s and the old check waited 0.5 s per port. Engine start went from 1.2 s to 0.2 s, and
  it no longer blocks the UI. Engines still start one at a time (`ENGINE_START`), so two tabs
  can't pick the same attach port.
- **Where:** [controller.rb](../../lib/tn3270/gui/controller.rb), [engine.rb](../../lib/tn3270/engine.rb).

### Redraw as soon as the worker sees a change
- **What:** when a session's screen changes, `Tab.on_change` posts one reused callback to the
  main thread with `uiQueueMain`, so the window redraws at once instead of on its next 25 ms
  timer tick.
- **Why:** measured from key press to screen, it took about 34 ms, of which the engine and
  drawing took about 6 ms; the rest was waiting for the timer, which Windows rounds up to about
  31 ms. Now it's about 6 ms. `UI.queue_main` wasn't used because the libui gem keeps every
  block passed to it alive forever.
- **Where:** `Program#start_wakeups`, `Tab.on_change`.

### The response timer is checked after reading the screen
- **What:** `Controller#refresh` reads the buffer first, then runs `time_response`.
- **Why:** the other way round, a screen that already showed the host's answer could still
  count as "waiting for the host" for one poll, so Escape did Reset instead of Clear. The same
  race made a test fail now and then.
- **Where:** `Controller#refresh`.

### The quick picker also switches settings
- **What:** every on/off menu item is registered as a toggle with extra search words. When the
  query matches, the picker lists those settings above the snippets with an ON/OFF badge, and
  Enter switches one exactly as its menu item does.
- **Why:** the user asked to change options like caps, auto enter and underline from the
  snippet search. Building the list from the menus means it can't fall out of step with them.
- **Where:** `Program#check_item` (`words:`), `Program.match_toggles`, `#flip`;
  `SnippetPanel#picker_items`, `#pick`, `#draw_setting_row`.

### Export / Import Settings, and `welcome.yml` for teams
- **What:** an export file holds the options you've changed, your sessions and your own
  snippets. Things tied to one computer stay out: recent sessions, the last connection, the
  engine path and the personal snippet path. Import merges: same-name sessions and snippets are
  replaced, the rest are kept, and the file's options win (ignored words, shared snippet files
  and key mappings are added to yours). A first launch with no settings imports a
  `welcome.yml`, looked for first in `RUBY3270_WELCOME`, then
  `%ProgramData%\ruby3270\welcome.yml`, then the program folder.
- **Why:** to hand ruby3270 to coworkers ready to use, without a program update ever
  overwriting their settings or the team's welcome file. Personal settings already live in the
  home folder. `welcome.yml` is in `.gitignore`, so the program never ships one. It's imported
  only once, and on that first launch it replaces the built-in demo session.
- **Where:** [settings_transfer.rb](../../lib/tn3270/gui/settings_transfer.rb),
  `TerminalWindow#export_settings`, `#import_settings`; `Program#run`.

### Spell checking uses the Windows spell checker through COM
- **What:** long input fields (20+ characters by default, never hidden ones) get red wavy
  underlines, with suggestions on right-click. All-caps words are checked like ordinary
  words, and things like `SYS1.PROCLIB` or `IEF142I` are skipped.
- **Why:** nothing to install, and it's the same dictionary Edge and Notepad use. The checker
  is only used on the main thread, because COM objects belong to the thread that made them.
- **Where:** [spell_checker.rb](../../lib/tn3270/gui/spell_checker.rb),
  [spelling.rb](../../lib/tn3270/gui/spelling.rb), [spell_ui.rb](../../lib/tn3270/gui/spell_ui.rb).

### README media is recorded from inside the app
- **What:** `script/readme_media/record.rb` runs the app against the fake host, drives it from
  code and records each frame's drawing calls. `render.py` redraws them with Pillow as a PNG
  and an animated GIF.
- **Why:** screen captures of the Direct2D window came out blank from the build shell, and
  simulated keystrokes went to whichever window had focus (they ended up in the editor once).
  Recording from inside needs no input and gives the same images every time. The cost is
  that fonts are drawn by Pillow, so text placement is close but not exact.
- **Where:** [script/readme_media/](../../script/readme_media/), images in [docs/images](../images/).

### Small changes
- The status bar no longer shows `PORT 3271`. The attach port is in the tooltip on the
  connection light.
- The window title is the tab's session name, never an IP address.
- Opening the SNIP sidebar widens the window and keeps its height.

## Follow-ups
- Tab drag, tear-out and merge were only tested with a simulated cursor. Clicks were tested
  by posting messages to the window, not with a real mouse.
- Renamed tab names aren't saved.
- Some imported options (view and menu checks) only show after a restart.
- Ideas not built yet: a team settings file layered under your own on every launch,
  settings an admin can lock, a `--config` option, per-session settings, and moving the
  cursor on screen before the host answers.
