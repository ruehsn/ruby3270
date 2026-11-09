# Background startup scripts and session editing (2026-11-09)

## Summary
Startup scripts now run in their own process instead of on the tab's worker thread. They attach to
their tab's session through its script port and are told which emulator started them and which
session to drive, through environment variables. Ruby, PowerShell, batch, Python and other files are
supported. Scripts and the ws3270 engines are tied to the app with Windows job objects, so none is
left running after ruby3270 closes or crashes.

On the session side:
- The saved-session list is gone from the Session menu.
- Tabs are renamed in place, inside the tab, instead of in a dialog.
- A new **Edit Session...** item opens the connection settings on the current tab's session.
- The Connections dialog gained a **Duplicate** button.

## Decisions
### Startup scripts run in their own process and attach over the script port
- **What:** `StartupScript.start` launches the file with `Open3.popen3` and returns right away. A
  Ruby file runs through `startup_runner.rb`, which calls `Session.attach` on the tab's port and
  evaluates the script with the same helpers as before (`fill`, `enter`, `status`, `connection`).
  It adds two new helpers, `emulator` and `session_name`. Other extensions run with their usual
  interpreter.
- **Why:**
  - The old in-process run blocked the tab: keys waited until the script ended. The user asked
    for scripts that keep running in the background without blocking the window.
  - The trade-off is that what you type while a script runs goes to the same session, so it can
    mix with the script's input.
  - The window picks up the script's changes on its normal poll, so the old proxy that redrew
    after every call was removed.
- **Where:** [startup_script.rb](../../lib/tn3270/gui/startup_script.rb) (`start`, `command`,
  `env`, `Context`), [startup_runner.rb](../../lib/tn3270/gui/startup_runner.rb),
  [controller.rb](../../lib/tn3270/gui/controller.rb) (`run_startup_script`,
  `stop_startup_script`).

### Scripts are told who started them through environment variables
- **What:** the variables are:
  - `TN3270_EMULATOR=ruby3270` and `RUBY3270_VERSION`
  - `TN3270_SESSION`
  - `TN3270_HOST` / `_HOST_PORT` / `_LU` / `_TLS` / `_ROWS` / `_COLS`
  - `TN3270_SCRIPT_HOST` / `_SCRIPT_PORT`
  - `RUBY3270_LIB` and `RUBY3270_CONNECTION` (JSON)
- **Why:** the user wanted one script shared by several emulators to tell which one started it,
  and to know which session to connect to. Environment variables work in every language. The
  emulator's own port is called `TN3270_SCRIPT_PORT` so it isn't confused with the host's port.
- **Where:** `StartupScript.env`.

### A tab with a startup script always opens a script port
- **What:** `wanted_port` is set when Allow Scripts to Attach is on, or when the connection has
  a script (`@script_wants_port`).
- **Why:** without a port, a background script has nothing to attach to.
- **Where:** `Controller#connect`, `Controller#wanted_port`.

### Script output goes to the status bar
- **What:** each line a script prints shows in the status bar. On failure, the status bar shows
  the runner's "Startup script failed (line N)" line, or otherwise the last line of stderr.
- **Why:** this works the same in any language, and Ruby's `status` simply prints a line.
- **Where:** `StartupScript.start`, `StartupScript.failure`.

### Job objects so no script or engine outlives the app
- **What:**
  - `Tn3270::ProcessJob` puts each startup script and each ws3270 engine in its own Windows job
    object with "kill on job close". Ruby's handle to the job is the only one, so Windows ends
    the job's processes when the app exits for any reason.
  - Stopping a script ends the whole job, including programs the script started.
  - On other systems, the script leads its own process group, and stopping it signals the group.
  - Ruby scripts run with `rubyw.exe`, so no console window opens.
- **Why:**
  - The user asked that long-running scripts never be left behind as orphans.
  - Testing showed 19 leftover ws3270 engines from runs that ended abruptly, so engines got the
    same treatment.
  - Stopping a script with `Process.kill` alone would leave its child processes running.
- **Where:** [process_job.rb](../../lib/tn3270/process_job.rb),
  [engine.rb](../../lib/tn3270/engine.rb) (`initialize`, `start_with_port`, `close`).

### Session menu without the saved-session list
- **What:** the "Session N" slots are removed, along with `Win32.reserve_slots` / `set_slots`.
- **Why:**
  - The new tab page already lists saved sessions, most recently used first.
  - The slots were placed by their position in the menu. After new items were added, that
    position was wrong: they showed dead "Session N" rows and replaced Allow Scripts to Attach.
- **Where:** [program.rb](../../lib/tn3270/gui/program.rb) `build_menus`,
  [win32.rb](../../lib/tn3270/gui/win32.rb).

### Rename tabs in place
- **What:** double-clicking a tab, or choosing Rename Tab, turns the tab's name into a text box.
  - Enter keeps the new name, and so does a click elsewhere.
  - Esc cancels.
  - An empty name goes back to the session name.
- **Why:** the user asked for in-place editing instead of a pop-up. The `TextDialog` was removed.
- **Where:** [terminal_window.rb](../../lib/tn3270/gui/terminal_window.rb) (`rename_tab`,
  `tab_edit_key`, `finish_tab_edit`, `draw_tab_edit`).

### Edit Session and Duplicate in the Connections dialog
- **What:**
  - `ConnectionsDialog` takes `select:`, which opens it on the tab's session. A typed
    `host:port` session is added to the list so it can be saved.
  - Saving updates the tab's name (`Controller#retarget`), but only for the entry the dialog
    opened on (`opened`).
  - Duplicate copies the selected entry and names it "Name (2)", "Name (3)", and so on
    (`copy_name`).
- **Why:** the user asked to edit and save the current session, and for a duplicate with a
  numbered name. Tracking `opened` fixes a bug found while testing in the real app: after
  Duplicate and Save, the open tab switched to the copy.
- **Where:** [dialogs.rb](../../lib/tn3270/gui/dialogs.rb), `TerminalWindow#edit_session`.

## Follow-ups
- A script in another language has to speak the s3270 protocol on the port itself. A small
  command-line helper could make that easier.
- What you type while a script is running can mix with the script's input. Typing could be
  paused while a script waits on the screen.
- On systems other than Windows, a crash of the app still leaves its scripts running (there is no
  job object there).
- Engines left over from before this change keep their ports until someone ends them.
