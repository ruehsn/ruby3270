# Quick pick recents, Stop Script in the picker, title bar double-click (2026-11-23)

## Summary
The quick picker (Ctrl+Space) can now run commands as well as snippets and
settings. The first command is Stop Script, which is the first entry while a
script runs on the tab. Opened with nothing typed, the picker lists the last 5
picks first, marked RECENT. Double-clicking the custom title bar now maximizes
or restores the window. The code for that was there before but never fired.
Release 0.1.4.

## Decisions
### Commands as a third kind of picker entry
- **What:** `QuickPick::Command` (name, label, search words, detail) sits
  beside `Program::Toggle` (settings) and snippet items. Picking one calls the
  window's `perform([name])`, the same path as menu items and key actions. The
  only command so far is `:stop_scripts`.
- **Why:** The request asked for Stop Script in the quick launch. Using
  `perform` means a new command needs only one line in `COMMANDS`.
- **Where:** [quick_pick.rb](../../lib/tn3270/gui/quick_pick.rb) `COMMANDS`,
  `match_commands`; [snippet_panel.rb](../../lib/tn3270/gui/snippet_panel.rb)
  `pick`, `command?`, `snippet?`.

### Recent picks
- **What:** Each pick is remembered by a key (`snippet:<name>`,
  `setting:<name>`, `command:<name>`), newest first, at most 5. The keys are
  saved as `recent_picks` in the config. With an empty query the picker lists
  Stop Script (while a script is busy), then the recent picks that still
  exist, then the other snippets. Typing searches as before (commands,
  settings, snippets) and ignores the recent list.
- **Why:** The request was to show the last 5 picks when the picker opens.
  Keys are names, not objects, so the list survives a restart, and a deleted
  snippet just drops out. It lives in the main config next to the existing
  `recent` connection list. A separate state file was considered but not used.
  Snippets with the same name in two files share one key; accepted as rare.
- **Where:** `QuickPick.items`, `.remember`, `.key_of`, `.recent?`;
  `SnippetPanel#picker_items`, `#recent_picks`, `#draw_recent_mark`;
  [config.rb](../../lib/tn3270/gui/config.rb) `recent_picks`.

### The ordering is kept out of the drawing code
- **What:** The list ordering is plain module functions that take every input
  as an argument.
- **Why:** So it can be unit tested without a window (`QuickPickTest`).

### Title bar double-click timed by the app
- **What:** A press on the caption counts as the second half of a
  double-click when it comes within the Windows double-click time
  (`GetDoubleClickTime`) and 4 px of the previous press, or when libui reports
  count 2. The toggle happens on the release, like the maximize button. A drag
  now starts only if the button is still held when the queued `begin_drag`
  runs.
- **Why:** The old check (`event[:count] >= 2`) never fired. The first press
  started Windows' move loop through `WM_NCLBUTTONDOWN`. When the button was
  already up, that loop took the second press as its release, so libui never
  saw two clicks. Testing also showed that `SC_MAXIMIZE` posted during the
  press had no effect, while posting it on the release (as the button does)
  works. The underlying cause of that was not found. Returning `HTCAPTION`
  from `WM_NCHITTEST`, which would let Windows do it all natively, was turned
  down as a bigger change: the menus and tabs share that strip.
- **Where:** [title_bar_view.rb](../../lib/tn3270/gui/title_bar_view.rb)
  `caption_double_click?`, `TitleBarView.double_click?`, `title_mouse_up`;
  [win32.rb](../../lib/tn3270/gui/win32.rb) `left_button_down?`,
  `double_click_seconds`, `TitleBar#begin_drag`.

## Follow-ups
- More commands could go in `QuickPick::COMMANDS`, for example reconnect,
  new tab or screenshot.
- Recent picks are shared by all windows and tabs; they aren't kept per
  session.
- With `custom_title_bar: false` the native title bar already does the
  double-click itself, so none of this applies there.
