# Program Settings, tabs from scripts, active tab and desktop shortcuts (2026-11-16)

## Summary
Global options moved into a new Session > Program Settings dialog, and the Connections... menu item went
(Edit Session covers it). Scripts can now open a new tab in the running window
(`Session.open_in_window`) and attach to a tab by its name (`Session.attach(tab:)`). The active tab
stands out among tabs of the same color. Saving a session no longer makes a desktop shortcut; a
Desktop Shortcut button does.

## Decisions
### Program Settings dialog; no Connections... menu item
- **What:** Session > Program Settings... holds the engine path (moved out of the connections dialog) plus
  type-ahead, digits-only fields, Keyboard Mapping, spell check (language, word list), snippets sidebar and
  files, and Lock Window Shape. Check boxes act at once through `Program#flip`, so the menu ticks stay in
  step; the engine path is kept by Save. The Connections... menu item is gone; the dialog still opens from
  Edit Session and the new tab page.
- **Why:** the user asked for one place for program-wide settings, and Edit Session already covers
  Connections. The matching menu items were left in place as well (not asked to remove them).
- **Where:** [dialogs.rb](../../lib/tn3270/gui/dialogs.rb) `SettingsDialog`, [program.rb](../../lib/tn3270/gui/program.rb) `build_menus`
  (toggles now have names: `:typeahead`, `:numeric_lock`, `:spell_check`, `:lock_ratio`),
  [terminal_window.rb](../../lib/tn3270/gui/terminal_window.rb) `settings_dialog`.

### Open a tab from a script: `Session.open_in_window`
- **What:** the script sends `{"host"|"session", "want" => "port"}` over the existing single-instance
  channel (`Instance`, token in `~/.ruby3270.instance`). The app opens the session (an idle tab first, else a
  new one), waits up to 10 s for the tab's script port and replies `ok <port>`; the script then attaches.
- **Why:** reuses the token-protected channel desktop shortcuts already use, so only the same user can do it,
  and the new tab works like any attached session. The instance server now answers each request on its own
  thread so one waiting for a tab doesn't hold up other launches.
- **Where:** [session.rb](../../lib/tn3270/session.rb) `open_in_window`, [instance.rb](../../lib/tn3270/gui/instance.rb)
  `open_tab`, `ask_port`, `answer`; [program.rb](../../lib/tn3270/gui/program.rb) `handle_request`, `answer_with_port`;
  `TerminalWindow#open_request` now returns the tab.

### Attach by tab name: `Session.attach(tab:)`
- **What:** the same channel with `{"tab" => name}`; the app finds the open tab whose title (renamed or not)
  or session name matches, any case, and replies with its port.
- **Why:** the user wanted a renamed tab to be what a script attaches to, instead of a port number.
- **Where:** [session.rb](../../lib/tn3270/session.rb) `attach`, `port_of_tab`; [instance.rb](../../lib/tn3270/gui/instance.rb)
  `find_tab`; [program.rb](../../lib/tn3270/gui/program.rb) `find_tab`.

### The active tab stands out
- **What:** a colored active tab gets a 0.30 wash, a 4 px top bar and colored sides; colored inactive tabs a
  0.10 wash and a thin faded bar. An uncolored active tab gets a thin blue top line; inactive titles are muted.
- **Why:** with every tab the same color it was hard to tell which was active.
- **Where:** [tab_strip_view.rb](../../lib/tn3270/gui/tab_strip_view.rb) `draw_tab`.

### Desktop shortcuts only on request
- **What:** Save no longer makes a shortcut; Edit Session has a Desktop Shortcut button (Windows) that saves
  and makes one. An existing shortcut follows its session: renamed (tracked in `@renamed`) it is remade
  under the new name, deleted it is removed. The `desktop_shortcuts` option is gone.
- **Why:** the user didn't want a shortcut for every saved session.
- **Where:** [dialogs.rb](../../lib/tn3270/gui/dialogs.rb) `ConnectionsDialog#make_shortcut`, `update_shortcuts`, `renamed_to`.

## Follow-ups
- A tab that isn't connected has no script port, so `attach(tab:)` can't find it until it connects.
- Program Settings options are also still in the Keys and View menus; remove them there if that's wanted.
- The new dialog, button and tab look were checked by scripted runs of the real app, not by hand.
- `{NewLine}` in a snippet and the earlier ideas list are unchanged from the previous session's follow-ups.
