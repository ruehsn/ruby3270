---
name: wrap
description: Wrap up a work session on ruby3270 - write a design-decisions doc for what changed, update the README, then commit and push to GitHub. Use when the user says "wrap", "wrap up", or "/wrap".
---

# Wrap up a session

Run these steps in order. Stop and tell the user if any step fails. Never skip
git hooks and never force-push.

## 1. See what changed

- `git status` and `git diff HEAD` (plus `git log origin/main..HEAD` for
  commits not pushed yet).
- Read the new files in full. Group the changes into features or decisions.

## 2. Write the design-decisions doc

Create `docs/decisions/YYYY-MM-DD-<short-topic>.md` (today's date; add `-2`
and so on if the name is taken). Make one file per session, not per feature.

```markdown
# <Topic> (YYYY-MM-DD)

## Summary
One paragraph: what this session added or changed, for someone new to the code.

## Decisions
### <Decision>
- **What:** the choice made.
- **Why:** the reason, plus the alternatives that were turned down and why.
- **Where:** [file.rb](../../lib/tn3270/gui/file.rb) and the key method names.

## Follow-ups
- Known gaps, caveats and ideas that were left for later.
```

Only record decisions you can see in the diff or in this conversation. Don't
invent reasons. If a reason isn't clear, write "Reason not recorded".

Then add a line for the new file to `docs/decisions/README.md` (newest first;
create the index if it's missing).

## 3. Update the README

- Add new user-visible features to the **Features** list in `README.md`, and
  change any lines the diff made out of date (keys, menus, config options).
  Keep the existing style: a bold name, where to find it, then one sentence.
- New config options go in the config section, with their defaults.
- If the screen looks different, or there's a new feature worth showing,
  rebuild `docs/images/main-window.png` and `docs/images/snippet-search.gif`
  with `script/readme_media/` (steps at the top of `record.rb`). It drives the
  app from inside, with no simulated keys, so you can run it yourself. Use a
  copy of `script/demo_home` as HOME, look at the frames before committing,
  and make sure the README links `docs/images/*`.

## 4. Check

- `bundle exec rake test` (or `ruby -Ilib -Itest -e 'Dir["test/*_test.rb"].each { |f| require "./#{f}" }'`).
  Don't commit if a test fails; report it.

## 5. Commit and push

- If on `main`, commit there (this repo is single-developer); otherwise commit on the current branch.
- Stage the files by name. Don't add scratch files, logs, `script/demo_home`
  config written back by a demo run, or anything that looks like a secret
  (hostnames, user IDs, passwords).
- Commit message: a short summary line, a blank line, then a bullet per
  feature. End it with the co-author line the session asks for.
- `git push origin <branch>`. If the push is rejected, stop and tell the
  user. Don't pull or rebase without asking.

## 6. Report

Tell the user in a few lines: the doc's path, what the README gained, the
commit hash and that it's pushed.
