# Review fixes, Paste the Rest, tab colors and the audit picture (2026-11-16)

## Summary
Esc on an unlocked keyboard no longer sends Clear, and a snippet's line breaks now line up under the
starting column like a paste. A code review then led to two bug fixes, several speed-ups, a split of the two
biggest GUI files, and three features: Paste the Rest, per-session tab colors, and a time-stamped picture
of the whole window for audit.

## Decisions
### Esc does nothing unless the keyboard is locked
- **What:** Esc is Reset while locked and otherwise ignored (it used to be Clear).
- **Why:** Clear wiped the screen by accident. First version used `return` inside the queued block, which
  killed the worker thread; it is now `next`.
- **Where:** [controller.rb](../../lib/tn3270/gui/controller.rb) `press`.

### Snippet line breaks follow the paste rules
- **What:** a line break in a snippet (and in a multi-line `{clipboard}` or `{ask}` value) moves to the same
  column on the next row, or the next input field below when that spot isn't an input (`Paste.target_for`).
  An explicit `{NewLine}` follows the same rule.
- **Why:** matches paste, so ISPF EDIT text lines up. `{NewLine}` can't be told apart from a typed line
  break in the parser; separating them was offered and not decided.
- **Where:** [snippet.rb](../../lib/tn3270/snippet.rb) `run(newline:)`, `Controller#snippet_line_break`.

### Engine actions can't contain line breaks
- **What:** `Engine#run` raises on `\r` / `\n`; `Engine.quote` turns a line break into the New Line key.
- **Why:** two actions in one write desynchronised every later answer (confirmed by test).
- **Where:** [engine.rb](../../lib/tn3270/engine.rb), [session.rb](../../lib/tn3270/session.rb) `type`.

### Unexpected errors don't end the worker
- **What:** `run_safely` and the poll `tick` rescue `StandardError` and show it in the status bar.
- **Why:** an uncaught bug stopped the tab taking keys with no sign why.
- **Where:** [controller.rb](../../lib/tn3270/gui/controller.rb).

### Performance
- **What:** tabs not on show poll every 0.5 s (`Controller#background=`); laid-out text is cached between
  frames in `Painter`; script waits and `text`/`line`/`lines` use the engine's `Ascii()` instead of building
  a `Screen` (checked identical, hidden fields blanked); `input_fields` and `find` are memoised per screen;
  history entries are stored deflated.
- **Why:** from the review. Not benchmarked beyond counting layouts (a redraw after a cursor move built 0).
- **Where:** [screen_painter.rb](../../lib/tn3270/gui/screen_painter.rb), [session.rb](../../lib/tn3270/session.rb),
  [screen.rb](../../lib/tn3270/screen.rb), [controller.rb](../../lib/tn3270/gui/controller.rb).

### Splitting the big files
- **What:** `terminal_window.rb` (1,741 lines) became the window plus `TabStripView`, `StartPage`,
  `StatusBar`, `TitleBarView`, `WindowShape`, `FindUi` and `Theme`; `Controller` gave up undo and script
  running; one `HitMap` replaced three hit-testing styles; toggles all go through `Program#flip`.
- **Why:** readability. Behaviour was meant to stay the same (tests plus a real-app run).
- **Where:** [terminal_window.rb](../../lib/tn3270/gui/terminal_window.rb), [hit_map.rb](../../lib/tn3270/gui/hit_map.rb),
  [controller_undo.rb](../../lib/tn3270/gui/controller_undo.rb), [controller_scripts.rb](../../lib/tn3270/gui/controller_scripts.rb).

### Paste the Rest
- **What:** lines a paste had no room for are kept (`@paste_rest`); Ctrl+Shift+V pastes them at the cursor,
  repeatably; the status bar shows `PASTE +n`.
- **Why:** pasting more lines than the screen holds used to lose the rest.
- **Where:** [controller.rb](../../lib/tn3270/gui/controller.rb) `paste_lines`, `paste_rest`; [paste.rb](../../lib/tn3270/gui/paste.rb) now returns how many lines it placed.

### Tab colors
- **What:** a connection's `color` tints its tabs and the top edge of the status bar. A saved session keeps
  it; a session that isn't saved has it for that tab only.
- **Why:** tell sessions apart (production). Storing it on the connection means every tab on it follows edits.
- **Where:** [tab.rb](../../lib/tn3270/gui/tab.rb) `color`, [tab_strip_view.rb](../../lib/tn3270/gui/tab_strip_view.rb),
  [dialogs.rb](../../lib/tn3270/gui/dialogs.rb).

### Audit picture
- **What:** Copy Window as Picture / Save Window as PNG. The status bar in the picture (only) shows full
  date, time, UTC offset, session, host and user.
- **Why:** `PrintWindow` and a screen copy both returned a blank Direct2D area, so the window's own drawing
  is repeated into a bitmap with GDI+ (`ImagePainter`) and the frame and key bar come from `PrintWindow`.
  This avoids needing the window in front, but text can differ from the live window by a pixel.
- **Where:** [screenshot.rb](../../lib/tn3270/gui/screenshot.rb), `TerminalWindow#audit_picture`, `StatusBar#audit_line`, [clipboard.rb](../../lib/tn3270/gui/clipboard.rb) `copy_image`.

## Follow-ups
- The new window code (menus, tab color popup, dialog field) was only exercised through a scripted run, not clicked through by hand.
- README images were not rebuilt; the default look is unchanged.
- README says "about 75 files load at startup"; it is now about 14 more.
- `{NewLine}` in a snippet could keep its old next-field behaviour if wanted.
- Ideas not done: auto-answer prompts, background-tab alerts, snippet recording, clickable PF labels, file transfer, auto-reconnect.
