# Choose with radio buttons and an Other box (2026-11-25)

## Summary
`Session#choose` now shows its options as radio buttons instead of a drop-down
list, and a new `other:` setting adds an **Other** choice with a text box, so
the person can type an answer that isn't in the list. Release 0.1.5.

## Decisions
### Radio buttons for up to 15 options, the list to scroll for more
- **What:** Up to 15 options (`ScriptPrompt::RADIO_MAX`) show as libui radio
  buttons. More keep the scrolling list from before (double-click picks).
- **Why:** Requested: radio buttons instead of the drop-down, so every choice
  is visible at once. Hundreds of radio buttons wouldn't fit in a window, so
  long lists stay a list. The limit of 15 is the one the drop-down used.
- **Where:** [script_prompt.rb](../../lib/tn3270/gui/script_prompt.rb)
  `add_choices`, `add_radios`, `window_height`.

### `other:` adds a choice with a text box
- **What:** `choose(..., other: true)` adds an "Other:" radio button with a
  text box under it. A string names the choice instead, for example
  `other: "Another LPAR:"`. Typing in the box selects Other. OK with Other
  selected and an empty box shows a note instead of closing. Under a long list
  the box is labelled "(used instead of the list)", and text in it wins over
  the list. A `default` that isn't one of the options starts the dialog with
  Other selected and that text in the box.
- **Why:** The request was an optional Other choice where text can be typed.
  It is off by default, so a plain `choose` still only returns a listed option.
- **Where:** `ScriptPrompt#add_other`, `#ok_other`, `#other_picked?`;
  [session.rb](../../lib/tn3270/session.rb) `choose`.

### What crosses the local channel
- **What:** An answer typed under Other comes back as
  `{"value" => text, "other" => true}`. `Session#choose` accepts an unlisted
  value only if the script asked for `other:` and the reply is marked
  `other`. It strips spaces and treats an empty answer as `nil`. When the
  request is checked, `other` becomes `"Other:"` if it is `true`, a string
  label is cut to 60 characters, and anything else drops the choice.
- **Why:** This keeps the earlier rule that `choose` returns only what the
  script allowed, and keeps the request's fields limited and checked like the
  rest.
- **Where:** [instance.rb](../../lib/tn3270/gui/instance.rb) `other_label`,
  `parse_ui`.

## Follow-ups
- The radio buttons have no double-click or Enter shortcut. You pick one,
  then press OK.
- The window height is estimated from the number of options; very long
  option names or a large Windows text size may need resizing by hand.
