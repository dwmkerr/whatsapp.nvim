# Agent notes

Instructions for coding agents working in this repository. `CLAUDE.md` includes this file.

## Layout

- `dist/` is the plugin: Go bridge in `dist/bridge`, Lua in `dist/lua`, tests in `dist/test`. The joke in the root `README.md` is that `dist/` is "compiled output"; keep that framing.
- Temporary files go in `./scratch/`, which is gitignored.

## Branches and pull requests

Never commit to `main` and never push to `main`. This holds for this repository and for every repository the maintainer owns or contributes to; it is the same rule as the maintainer's open-source project workflow. Every change, however small, goes on a branch and arrives through a pull request, including documentation, screenshots and one-line fixes.

- Do not push anything unless asked. Pushing a branch to open a pull request the maintainer asked for counts as asked.
- Never force-push unless the maintainer asks for that specific force-push.
- If you find local commits on `main`, stop and ask before doing anything else.

## Working

- Build with `make build`, test with `make test`. Run the tests before every commit and check the exit code, not just the tail of the output.
- Conventional commit messages: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`.
- Comments explain why, never what changed.
- Discuss UI and keybinding changes before building them. Prefer idioms Vim users already know (`gx`, `]m` `[m`, `<CR>` as the primary action, `g?` for help).

## Design principles

- **Focus never decides whether a shortcut exists.** A key that acts on the conversation (`gx`, `]m` `[m`, `K`, `L`) works from the chat list and the compose pane too, unless that pane already uses the key for its own job (`<CR>` opens a chat in the list). Dissonance between panes is a bug.
- One hint, on the thing it describes. Keys are shown next to the target (splash, media hint, winbar), in `Special` for the key and `Comment` for the words.
- Read state, presence and typing mirror the phone. If the phone would show it, the plugin shows it; if the phone would send it, the plugin sends it.

## Screenshots and personal data

Screenshots of a real account show other people's names, numbers and words. They are never committed, attached to an issue or pull request, or pasted into a document until the maintainer has reviewed the final masked file and said yes to that file. No exceptions for "temporary", "draft" or "will fix later". Ask every time.

How to mask, before asking for review:

1. Prefer synthetic data. Take screenshots against the fake bridge (`dist/test/fake-bridge.sh`) or a chat with yourself, with invented names and messages. A real screenshot is a last resort.
2. Names: first name only, or a made-up name. Remove surnames everywhere, including group titles, the chat list, bubble headers and the winbar. Replace contact names that are phone numbers with a made-up name.
3. Phone numbers: remove completely, in the winbar, the chat list, the compose bar and message text. Do not blur; blurred digits can be recovered.
4. Message text: only text written by the maintainer or invented for the shot. Other people's messages are cut or replaced, including quoted replies and media captions.
5. Group names, places, employers, schools and dates that identify a person are replaced.
6. Pairing QR codes are secrets while valid. Only use a code that has expired or been invalidated by `:WhatsApp logout`, and prefer a fake code from the fake bridge.
7. Crop to the plugin. Terminal tabs, tmux status lines and other windows often leak project or client names.
8. Check the file at full size after editing, then list each change made when asking for review.

Keep originals outside the repository (`./scratch/` is gitignored). Never commit a file that only reads "TODO mask".
