# Script questions (ask, choose, show, notify) and Stop Script (2026-11-23)

## Summary
Scripts can now ask the person at the window for text (`Session#ask`), have
them pick from a list (`#choose`), show them read-only text (`#show`) and put a
message in the tab's status bar (`#notify`). Each question or report opens a
small window of its own over the terminal window, so nothing typed goes into
the 3270 screen. Scripts can also be stopped from the window: the STOP button
in the status bar, Session > Stop Scripts, the `stop_script` key action, or the
Stop Script button in a question. The example is `examples/ask_the_user.rb`
and the docs are in `docs/API.md`, "Asking the person at the window".
Release 0.1.3.

## Decisions
### Questions go through the single-instance channel
- **What:** A script sends `{"token", "ui": {...}}` to the existing local
  Instance server (the one `open_in_window` uses) and waits for a JSON reply.
  The request carries the script's tab port, so the question opens over the
  right tab.
- **Why:** The script port (ws3270) only speaks the emulator's protocol and
  can't show windows. Instance already has a token-checked local connection
  into the running program, so no new port or authentication was needed. The
  cost: these calls need `single_instance` on (the default).
- **Where:** [instance.rb](../../lib/tn3270/gui/instance.rb) `user_request`,
  `parse_ui`, `answer_user_request`;
  [session.rb](../../lib/tn3270/session.rb) `ask`, `choose`, `show`, `notify`.

### Requests are checked before anything is shown
- **What:** `parse_ui` keeps only known kinds (ask, choose, show, notify) and
  fields, with length limits: title 200 characters, prompt and default 2,000,
  text 200,000, up to 500 options of up to 200 characters each. A ui request
  line may be up to 300,000 bytes; open requests keep the old limit.
- **Why:** Anything holding the token could otherwise make the program build
  huge windows. `choose` only ever returns one of the listed options.
- **Where:** [instance.rb](../../lib/tn3270/gui/instance.rb) `parse_ui`,
  `MAX_UI_LINE`, `MAX_TEXT`.

### Separate windows that don't block the terminal
- **What:** Questions and text windows are ordinary libui windows owned by the
  terminal window (Win32 `GWLP_HWNDPARENT`) and centred over it. They are not
  modal. A `show` window gives the keyboard back to the terminal straight
  after it opens.
- **Why:** The request was to show things "without interfering with 3270
  input". Ownership keeps the window in front of the terminal without locking
  the terminal.
- **Where:** [script_prompt.rb](../../lib/tn3270/gui/script_prompt.rb)
  `ScriptPrompt`, `ScriptTextWindow`, `place_over`;
  [win32.rb](../../lib/tn3270/gui/win32.rb) `set_owner`.

### Choice list form depends on size
- **What:** Up to 15 options show as a drop-down list. More show as a list to
  scroll, where double-click picks.
- **Why:** A long drop-down is hard to scan. Reason for 15 exactly not recorded.
- **Where:** `ScriptPrompt#add_choices`.

### `show` reuses its window and uses a monospace font
- **What:** Calling `show` again with the same title on the same tab replaces
  the text in the open window. The text box uses Consolas. `wait: true` waits
  until the window closes.
- **Why:** Lets a script keep one progress window up to date. Screen text lost
  its columns in the proportional default font. Carriage returns are removed
  because libui adds its own and they doubled up.
- **Where:** `ScriptTextWindow#update`, `ScriptPrompts#script_show`,
  [win32.rb](../../lib/tn3270/gui/win32.rb) `monospace`.

### Every request is answered once; a vanished script is noticed
- **What:** Each request gets exactly one reply: a value, cancel, stop or ok.
  Closing a question counts as cancel. While waiting, Instance checks every
  half second whether the script's connection has gone. If it has, the
  question closes without an answer.
- **Why:** So a script killed mid-question doesn't leave an orphan window, and
  the program never waits on a reply nobody will read.
- **Where:** `Instance#answer_user_request`, `ScriptPrompt#finish`, `#gone`,
  `ScriptPrompts#script_request_gone`.

### Stop Script
- **What:** Stopping (status-bar STOP button shown while a script is busy,
  Session > Stop Scripts, the `stop_script` key action with no default key)
  answers the tab's open questions with "stop" and kills the scripts the tab
  started through their job object. A "stop" reply makes the waiting call
  raise the new `Tn3270::ScriptStopped`. Startup and script-folder scripts
  catch it and end quietly, and the status bar says "Script stopped" instead
  of reporting a failure.
- **Why:** The request asked for a way to stop a script. An exception unwinds
  the script cleanly at the point it was waiting.
- **Where:** [controller_scripts.rb](../../lib/tn3270/gui/controller_scripts.rb)
  `stop_scripts`, `scripts_running?`;
  [startup_script.rb](../../lib/tn3270/gui/startup_script.rb) `Running#stop`,
  `Context.run`;
  [terminal_window.rb](../../lib/tn3270/gui/terminal_window.rb) `stop_scripts`,
  `script_busy?`; [status_bar.rb](../../lib/tn3270/gui/status_bar.rb);
  [engine.rb](../../lib/tn3270/engine.rb) `ScriptStopped`.

## Follow-ups
- Ruby scripts only. PowerShell and batch scripts can't ask yet (they would
  need a small command-line helper).
- A script started by hand from a command prompt can only be stopped from the
  window at its next question. Ctrl+C in its console still works.
- Without `single_instance`, the calls raise an error rather than falling back
  to a console prompt.
- The Ruby setup here crashes in `prism`/error_highlight when formatting some
  exceptions. Use `RUBYOPT=--disable-error_highlight` when debugging.
