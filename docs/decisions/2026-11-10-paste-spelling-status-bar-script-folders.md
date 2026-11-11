# Paste, spelling words, status bar and script folders (2026-11-10)

## Summary
This session added:
- **Multi-line paste:** each line lines up under the column the paste started in. The fake host has an
  ISPF-style editor to test it against.
- **Spelling word files:**
  - a built-in list of mainframe terms
  - a site-wide `spelling.txt`
  - extra lists named in the `spell_word_files` setting
  - your own ignored words, now in a plain text file of their own (`~/.ruby3270-spelling.txt`)
- **Menus:** items show their keyboard shortcut on the right.
- **Status bar:**
  - shows the response time and when the host was last heard from
  - the connection details moved into the green light's tooltip
  - cursor coordinates are as wide as the screen size needs
- **Connections dialog:** Rows and Columns can always be typed.
- **Script folders:** scripts in a folder show in the snippet list with a name and description taken from
  their top comments, and run in the background on the session.

## Decisions
### Multi-line paste keeps the starting column
- **What:** `Paste.plan` turns a paste into move/type steps:
  - Line *n* goes in the same column one row down.
  - If that row has no input field at that column (a form), the line goes in the next input field below.
  - Each line is cut at the end of its field, and the paste stops at the bottom of the screen.
  - The status bar says when lines were cut or left out.
- **Why:**
  - Pasting JCL or code into ISPF EDIT would otherwise put line 2 in the line-number field.
  - Cutting lines at the field end keeps text from spilling into the next field.
- **Where:** [paste.rb](../../lib/tn3270/gui/paste.rb) (`plan`, `target_for`, `room_at`, `note`). The
  editor (option 5) in [fake_host.rb](../../lib/tn3270/fake_host.rb) is there to test it.

### Ignored words live in their own text file
- **What:**
  - **Ignore Word** appends to `~/.ruby3270-spelling.txt` (its path can be changed with the
    `personal_spelling` setting).
  - An old `spell_ignore` list in the config is moved into the file once.
  - View > Edit My Spelling Words opens the file in Notepad, and edits are picked up within about 2 seconds.
  - Export/Import Settings still carries the words.
- **Why:** the user asked for "a separate file for easier sharing and editing". A plain one-word-per-line
  file can be edited by hand and copied to a colleague. A list buried in the YAML config can't.
- **Where:** [spell_words.rb](../../lib/tn3270/gui/spell_words.rb) (`add`, `migrate`, `paths`, `stamp`),
  [spell_ui.rb](../../lib/tn3270/gui/spell_ui.rb) (`reload_spell_words`, `edit_spell_words`,
  `open_in_editor`), [settings_transfer.rb](../../lib/tn3270/gui/settings_transfer.rb).

### Word lists stack in layers
- **What:** spell check reads these lists, in this order:
  1. the built-in `mainframe_words.txt`, replaced by program updates
  2. your own file
  3. `spelling.txt` in ProgramData or the program folder, for a site
  4. any files listed in `spell_word_files`, for a team
- **Why:**
  - Common mainframe terms (JCL, SDSF, IEFBR14...) should never be flagged out of the box.
  - Sites and teams need a place for their own terms that updates don't overwrite.
  - `/spelling.txt` is git-ignored, like `welcome.yml`, so a site's list never ends up in the repo.
- **Where:** [spell_words.rb](../../lib/tn3270/gui/spell_words.rb),
  [mainframe_words.txt](../../lib/tn3270/gui/mainframe_words.txt).

### Menu shortcuts are drawn by Windows after a tab
- **What:**
  - On Windows, a menu label is `"Label\tCtrl+C"`, so Windows right-aligns the key.
  - The key comes from the current key bindings.
  - After a rebind in Keys > Keyboard Mapping, every window relabels its items with `SetMenuItemInfoW`.
- **Why:**
  - Windows draws the tab-separated part right-aligned, so libui needs no custom drawing.
  - Relabelling keeps the shown keys in step with what the keys actually do.
  - The window's custom title bar detaches the menu bar, so `MenuBar` keeps its own handle (`GetMenu`
    returns nothing).
- **Where:** [program.rb](../../lib/tn3270/gui/program.rb) (`SHORTCUTS`, `menu_text`, `menu_texts`,
  `reload_bindings`), [win32.rb](../../lib/tn3270/gui/win32.rb) (`MenuBar#relabel`, `set_item_text`).

### Status bar: timing up front, details on hover
- **What:**
  - The left side shows `0.12s  heard 14:03:27`.
  - The address, port, session name, timing, colour legend and script port moved into the
    connection light's tooltip.
  - The cursor position is zero-padded to the width of the screen size (`05/12` on 24x80, `005/012` on
    160x62), and its tooltip gives the screen size.
  - "Heard" changes only when the host sent new records (`records_received`), not on every redraw.
- **Why:**
  - The user asked for all of this.
  - Tooltip widths now measure the bold heading, which fixes the squished tooltip.
- **Where:** [terminal_window.rb](../../lib/tn3270/gui/terminal_window.rb) (`host_timing`,
  `cursor_position`, `connection_tip`), [controller.rb](../../lib/tn3270/gui/controller.rb)
  (`note_heard`, `last_heard`), [font_metrics.rb](../../lib/tn3270/gui/font_metrics.rb) (`bold:`).

### Print Screen is left alone
- **What:** no code change. The app has no keyboard hooks or hotkeys, and in a probe the Print Screen
  key never reached its key handler.
- **Why:** the reported capture of Print Screen couldn't be reproduced, so the user was given things to
  check instead: the Windows setting "Use the Print screen key to open screen capture", and other tools
  that claim the key.
- **Where:** nothing was changed.

### Rows and Columns are always editable
- **What:** the spin boxes are always enabled. Typing a value selects the matching preset, or Custom.
- **Why:** the user asked to type custom sizes without first picking Custom.
- **Where:** [dialogs.rb](../../lib/tn3270/gui/dialogs.rb) (`size_typed`, `size_picked`),
  [ui.rb](../../lib/tn3270/gui/ui.rb) (`spinbox` with an on-change block).

### Script folders join the snippet list
- **What:**
  - The new `script_folders` setting lists folders. The scripts in them (.rb .rbw .ps1 .bat .cmd .py
    .vbs .js) are added to the snippet library as read-only items.
  - The name and description come from the comment block at the top of the file. An optional `Name:`
    line sets the name; otherwise it comes from the file name.
  - Each language's comment marker is understood.
  - Running a script uses the same background runner as startup scripts, against the tab's session.
  - Scripts stop when the tab connects again, disconnects or closes.
- **Why:**
  - The user asked for the description to come from the script's own comments.
  - Comments need no separate metadata file and already describe the script.
  - Reusing the startup-script runner gives the same environment variables, status lines, error
    reporting and job-object cleanup.
- **Where:**
  - [script_info.rb](../../lib/tn3270/gui/script_info.rb) (`read`, `name_from_file`)
  - [snippet_library.rb](../../lib/tn3270/gui/snippet_library.rb) (`script_files`, `add_script_folder`)
  - [controller.rb](../../lib/tn3270/gui/controller.rb) (`run_script`, `start_script`, `wanted_port`)
  - [snippet_panel.rb](../../lib/tn3270/gui/snippet_panel.rb)
  - [snippet_dialogs.rb](../../lib/tn3270/gui/snippet_dialogs.rb) (Add Script Folder...)

### A script folder opens the script port
- **What:** `wanted_port` asks for a script port when any script folder is set, even with
  "Allow Scripts to Attach" off.
- **Why:** scripts can only drive the session through that port.
- **Trade-off:** the port only opens when the tab connects. If you add your first folder while
  connected, you have to reconnect once, and the status bar says so.
- **Where:** [controller.rb](../../lib/tn3270/gui/controller.rb) (`wanted_port`, `run_script`).

## Follow-ups
- **Print Screen:** waiting on the user's answers to the checks above.
- **Script port:** adding the first script folder could open the port without a reconnect.
- **Rows/Columns:** typing into the boxes was not tried in the real dialog. Only the enabled state was
  seen on screen.
- **Script input:** a script and your typing go to the same session, so they can mix (the same as
  startup scripts).
- **Script folders:** only the top level of a folder is listed, not subfolders.
