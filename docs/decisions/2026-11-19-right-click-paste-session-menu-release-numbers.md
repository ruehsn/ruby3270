# Right-click paste, Session menu groups and release numbers (2026-11-19)

## Summary
Release 0.1.1. A right-click on the terminal with nothing selected now pastes, the
Session menu is split into groups, and each wrap-up now raises the release number
shown in Help > About.

## Decisions
### Right-click with nothing selected pastes at the cursor
- **What:** Right-click now does one of three things. With a selection, it copies
  and moves the cursor to the pointer, as before. On a red-underlined word, it opens
  the spelling suggestions, as before. Anywhere else, it pastes the clipboard at the
  text cursor, the same as Ctrl+V.
- **Why:** The user asked for paste on right-click when nothing is selected. Copy on
  right-click and paste on right-click together work like a common terminal habit.
  The paste goes where the text cursor is and does not move the cursor to the
  pointer first, so it matches Ctrl+V and the Edit menu. Pasting where you click
  was considered but not chosen; it is a one-line change if wanted.
  Spelling still comes first, so suggestions stay reachable.
- **Where:** [terminal_window.rb](../../lib/tn3270/gui/terminal_window.rb)
  `right_click`; the help line in [keymap.rb](../../lib/tn3270/gui/keymap.rb).

### Session menu in groups
- **What:** The Session menu now has groups split by separators: opening things
  (New Tab, New Window, Duplicate Tab), this tab (Rename, Tab Color, Move to New
  Window, Close), this tab's connection (Connect / Disconnect, Edit Session),
  the whole program (Program Settings, Allow Scripts to Attach), settings files
  (Export, Import), then Quit.
- **Why:** The user asked for more grouping. Before, tab, session and program
  items were mixed in one long list (Program Settings sat between Edit Session and
  Close Tab).
- **Where:** [program.rb](../../lib/tn3270/gui/program.rb) `build_menus`.

### Each wrap raises the release number
- **What:** The `/wrap` skill now adds one to the last part of `Tn3270::VERSION` once per
  wrap, puts the number in the decisions doc and in the commit summary line
  (`[0.1.1]`), and gives it in the report.
- **Why:** The user asked for the release number in Help > About to go up on each
  wrap. The first and middle numbers change only when the user asks.
- **Where:** [.claude/skills/wrap/SKILL.md](../../.claude/skills/wrap/SKILL.md);
  [lib/tn3270.rb](../../lib/tn3270.rb) `VERSION`.

## Follow-ups
- Right-click paste was not tried in the running app; only the test suite was run.
- An option for right-click to paste where you click could be added if people
  expect that.
