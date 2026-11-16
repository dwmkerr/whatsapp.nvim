---
name: resolve-issue
description: Make a zero-shot first attempt at a GitHub issue or a drift report (the phone shows one thing, the plugin another), ending in a pull request with before/after recordings of the synthetic account, or an issue comment explaining why not. Use when the user says "resolve issue #N", "fix this drift", "zero-shot this", or shares a phone screenshot that disagrees with the plugin.
---

# Resolve an issue

A first attempt without a human in the loop: from an issue or a drift report to a reviewable pull request in one pass. The maintainer reviews it, then merges, asks for changes or takes over. A clear pull request that fails honestly is worth more than a polished one that hides a guess.

Running this skill is the maintainer's go-ahead to create an issue, push a branch to the fork and open a pull request. Never push to `main`, never force-push, never merge. Follow `AGENTS.md` throughout.

## The rule on personal data

This repository is public, and so are its issues, pull requests and the `pr-assets` branch. Evidence comes only from the synthetic account in `dist/test/fixtures/synthetic.json`. A drift report from the maintainer's phone or real account is read, never quoted: no real names, numbers, group titles, message text or screenshots go into an issue, pull request, commit or file. Describe the behaviour in terms of the synthetic account ("an archived group with 39 unread shows at the top of the list"). See "Screenshots and personal data" in `AGENTS.md`.

## 1. Find the work

- **An issue**, `#27`: `gh issue view 27 --repo dwmkerr/whatsapp.nvim --json number,title,body,labels,comments`.
- **A drift report**: the maintainer shows the phone and the plugin disagreeing. Compare them, list each difference, and work out which part of the bridge or plugin owns it. Then raise one issue per difference, written in synthetic terms only:

  ```bash
  gh issue create --repo dwmkerr/whatsapp.nvim --title "fix: archived chats show in the chat list" --body-file scratch/resolve-<slug>/issue.md
  ```

  The body says what the phone shows, what the plugin shows, and the suspected cause with file and line. Fix one issue per run; leave the rest for later runs.

## 2. Decide whether to attempt it

Stop and comment on the issue instead of coding when any of these hold:

- It changes the UI or keybindings in a way the issue doesn't settle. `AGENTS.md` asks for that discussion first.
- It changes what the plugin sends to WhatsApp (receipts, presence, app state patches) in a way that could surprise contacts or risk the account.
- The fix is clearly bigger than about 10 files or 300 lines.
- You can't reproduce it in the synthetic account.

The comment says what you found: where the code is, the likely cause, the options and which you'd pick. That is a good outcome, not a failure. Shape it like the pull request body (step 7).

## 3. Branch and reproduce in the synthetic account

The working tree must be clean apart from untracked files.

```bash
git fetch origin
git switch -c fix/<issue>-<short-slug> origin/main    # feat/ for features
```

Read [`docs/development.md`](../../../docs/development.md) for the fixture format. Add the smallest set of events that reproduces the issue to `dist/test/fixtures/synthetic.json`, with a `note` naming the issue. Keep existing chats and ids as they are, so earlier recordings stay comparable; add new people and chats instead. Use invented names and `+44 7700 900xxx` numbers. Check the account with `make demo`.

Commit the dataset change on its own first (`test: reproduce #<issue> in the synthetic account`). The "before" is recorded with that commit and the code from `main`.

Pick the evidence that fits:

| Issue type | Evidence |
| --- | --- |
| Anything visible in the plugin | Before/after GIF and screenshots of `make demo`, recorded with Shellwright (step 4) |
| Bridge logic (history, read state, archive, names) | The recording, plus a Go test that fails before the fix and passes after |
| Lua logic with nothing to see | A test in `dist/test/run.lua` against the fake bridge that fails before and passes after |
| Pictures (Kitty graphics) | Shellwright can't render them yet ([shellwright#86](https://github.com/dwmkerr/shellwright/issues/86)). Ask the maintainer for a Ghostty screenshot of `make demo`, and say so in Checks |

To show a new test fails before the fix, stash only the source change: `git stash push <src files>`, run `make test`, `git stash pop`. Put the failing count in Checks.

## 4. Record "before"

Write the steps once to `scratch/resolve-<issue>/script.json` and use the same file for before and after, so the recordings differ only by the code:

```json
{
  "steps": [
    {"until": "connected", "timeout": 30000, "wait": 2500},
    {"screenshot": "list"},
    {"keys": "u", "wait": 1500},
    {"screenshot": "chat"}
  ]
}
```

`until` waits for text on screen, `wait` is milliseconds, `keys` are typed as given (`\r` is Enter, `\u001b` is Escape) and `screenshot` saves a PNG. Then:

```bash
python3 -I .claude/skills/resolve-issue/record.py scratch/resolve-<issue>/script.json scratch/resolve-<issue> before
```

`record.py` starts a Shellwright server if none is running, builds the bridge, runs `make demo` in a 110x30 terminal, plays the steps and writes `before.gif` (trimmed), `before-raw.gif` and `before-<name>.png`. `trim-gif.py` cuts long pauses to 1.2 seconds, plays the rest 1.5 times faster, holds the last frame for 2.5 seconds and scales to 1200 pixels wide. Aim for under about 2 MB and under 15 seconds; cut steps rather than speed up further.

A recording takes about two minutes, because Shellwright renders frames slowly ([shellwright#88](https://github.com/dwmkerr/shellwright/issues/88)). The same issue means recordings capture a frame every couple of seconds, so a state that lasts under a second may not appear; use a screenshot step for anything that must be seen. The Shellwright MCP tools (`.mcp.json`) are there for exploring the demo by hand.

Look at every screenshot and the GIF's last frame before going on (`ffmpeg -i before.gif -vf "select=eq(n\,N)" -frames:v 1 frame.png`). The before must show the problem to someone glancing at it. If it doesn't, you haven't reproduced it.

## 5. Make the change

- Follow `AGENTS.md` and the code around the change. Comments explain why.
- Add or update a test that fails before the fix.
- Run `make test` and check the exit code, not just the tail.

## 6. Record "after" and upload

Run `record.py` again with the same script and the label `after`. Compare each pair. If the after doesn't show the fix, keep working or say so in the pull request.

Evidence goes on the `pr-assets` branch of the fork, one folder per issue. Upload only the before and after files:

```bash
D=scratch/resolve-<issue>
for f in $D/before.gif $D/after.gif $D/before-*.png $D/after-*.png; do
  [ -f "$f" ] || continue
  case "$f" in *-raw.gif) continue ;; esac
  base64 -i "$f" | tr -d '\n' > "$f.b64"
  gh api -X PUT "repos/gaspodethewon/whatsapp.nvim/contents/<issue>/$(basename "$f")" \
    -f message="chore: evidence for #<issue>" -f branch=pr-assets -F content=@"$f.b64" --jq .content.path
done
```

Each file's URL is `https://github.com/gaspodethewon/whatsapp.nvim/blob/pr-assets/<issue>/<file>?raw=true`. Re-uploading a path needs `-f sha=<blob sha>`, so prefer new names (`after-2.gif`).

## 7. Open the pull request

The `gh` account is `gaspodethewon`, which can't push to `dwmkerr/whatsapp.nvim`, so branches go to the `fork` remote:

```bash
git push -u fork HEAD
gh pr create --repo dwmkerr/whatsapp.nvim --base main --head gaspodethewon:<branch> \
  --title "<conventional commit title>" --body-file scratch/resolve-<issue>/pr.md
```

Open it as a draft (`--draft`) when the fix is partial or a surface is unchecked.

The body leads with the key message: Summary, the before and after table, Checks, then "Still open" if a problem remains. Everything else (the traced code path, extra shots, long notes) goes in one collapsed `Details` block. The Zero-shot footer is last. Caption every cell in under ten words: what's wrong in the before, what's fixed in the after.

````markdown
## Summary
- <what changed and why, 1-3 bullets>

Closes #<issue>

## Before and after
| | Before | After |
| --- | --- | --- |
| Chat list | <img src="https://github.com/gaspodethewon/whatsapp.nvim/blob/pr-assets/<issue>/before-list.png?raw=true" width="480"><br><what's wrong> | <img src="...after-list.png?raw=true" width="480"><br><what's fixed> |
| Recording | <img src="...before.gif?raw=true" width="480"><br><what's wrong> | <img src="...after.gif?raw=true" width="480"><br><what's fixed> |

## Checks
- `make test`: <result>; the new test fails before the fix (<n> failures)
- Synthetic account: <events added to the dataset and why>
- <anything not checked and why>

<details><summary>Details</summary>

<traced code path, other notes>

</details>

## Zero-shot
First attempt by the `resolve-issue` skill. Review it, then merge, ask for changes or take it over.
````

To change the body later: `gh api -X PATCH repos/dwmkerr/whatsapp.nvim/pulls/<n> -F body=@scratch/resolve-<issue>/pr.md`.

## 8. Report

Give the maintainer the pull request URL (or the issue comment URL if you stopped at step 2), the issue number and whether you created it, and anything you didn't check or weren't sure of.
