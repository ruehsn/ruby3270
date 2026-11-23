# Win+V paste, Refresh Snippets and spelling patterns (2026-11-23)

## Summary
Release 0.1.2. Picking an item from the Windows clipboard history (Win+V) now
pastes into the terminal. A new Refresh Snippets command reads every snippet file
and script folder again without restarting. Spell check now skips words shorter
than a set length (by default 3-letter words), and the spelling word lists accept
simple wildcard patterns such as `AC??????`.

## Decisions
### Fill in missing scan codes so injected keys reach libui
- **What:** A thread message hook (`WH_GETMESSAGE`) looks at each keyboard message
  before libui does. When a key arrives with no scan code, the hook fills one in
  from its virtual-key code (`MapVirtualKeyW`).
- **Why:** Win+V pastes by sending a fake Ctrl+V through `SendInput` with only a
  virtual-key code. libui's drawing area recognizes letters and digits only by
  scan code, so it dropped the "V" and saw only Ctrl. A test window confirmed this:
  without the hook only Ctrl arrived; with it, Ctrl+V did. Subclassing the area's
  window was not used, because libui handles key messages in its message loop
  before they are dispatched to the window. A hook that only listens for Win+V was
  not chosen either: this fix also covers AutoHotkey, password managers and other
  tools that send keys the same way.
- **Where:** [win32.rb](../../lib/tn3270/gui/win32.rb) `Win32.fill_missing_scan_codes`,
  installed once in [program.rb](../../lib/tn3270/gui/program.rb) `run` after `UI.init`.

### Refresh Snippets reloads files even if their time didn't change
- **What:** Edit > Refresh Snippets (read the files again), and a Refresh Snippets
  button in Program Settings. These reload every snippet file and script folder,
  update the sidebar in every window, and report the count (and any unreadable
  files) in the status bar.
- **Why:** The user had to restart the program to see some snippet changes.
  Automatic reloading only happens when a file's time or the file list changes, and
  a file replaced on a network drive can keep its old time.
- **Where:** [snippet_library.rb](../../lib/tn3270/gui/snippet_library.rb) `reload`;
  [snippet_panel.rb](../../lib/tn3270/gui/snippet_panel.rb) `refresh_snippets`.

### Skip short words in spell check (`spell_min_word`, default 4)
- **What:** Words shorter than `spell_min_word` letters are not checked. The default
  is 4, so 3-letter words are skipped. Program Settings > Spelling has a number box
  for it, which takes effect at once.
- **Why:** The user asked to ignore 3-letter words, which on a mainframe are mostly
  codes. `Spelling` itself still defaults to 3, so it behaves as before when used
  without the setting.
- **Where:** [spelling.rb](../../lib/tn3270/gui/spelling.rb) `min_word`,
  `Spelling.words(value, min:)`; [spell_ui.rb](../../lib/tn3270/gui/spell_ui.rb)
  `set_spell_min_word`; [config.rb](../../lib/tn3270/gui/config.rb) default.

### Wildcard patterns in spelling word lists, without regex
- **What:** In any spelling word list, an entry containing `?` (any one letter) or
  `*` (any letters, or none) is a pattern. Patterns ignore case. `AC??????` skips
  every 8-letter word starting with AC. "AC or AH" takes two lines.
- **Why:** The user asked for patterns but no regex, for security and simplicity.
  A hand-written matcher knows only `?` and `*`; every other character must match
  itself. It uses the two-pointer method that goes back to the last `*` on a
  mismatch, so no pattern can make it slow. `File.fnmatch` was not used because it
  also supports `[...]`, `{...}` and escapes, which is more syntax than asked for.
  Patterns go in the existing word list files, not the main settings file, so
  `.ruby3270.yml` stays short.
- **Where:** [spelling.rb](../../lib/tn3270/gui/spelling.rb) `WordPattern`,
  `Spelling#ignored=` (splits plain words from patterns);
  [spell_words.rb](../../lib/tn3270/gui/spell_words.rb) header text.

## Follow-ups
- The Win+V fix was checked with a test window and injected keys, but not yet by
  hand in the full app.
- Refresh Snippets has no default shortcut; it could be added to the Keyboard
  Mapping actions.
- Patterns can't express "AC or AH" in one line; `[CH]`-style sets were left out to
  keep the syntax small.
