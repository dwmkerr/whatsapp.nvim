# Agent notes

Instructions for coding agents working in this repository. `CLAUDE.md` includes this file.

## Layout

- `dist/` is the plugin: Go bridge in `dist/bridge`, Lua in `dist/lua`, tests in `dist/test`. The joke in the root `README.md` is that `dist/` is "compiled output"; keep that framing.
- Temporary files go in `./scratch/`, which is gitignored.

## Working

- Build with `make -C dist build`, test with `make -C dist test`. Run the tests before every commit and check the exit code, not just the tail of the output.
- Conventional commit messages: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`.
- Comments explain why, never what changed.
- Discuss UI and keybinding changes before building them. Prefer idioms Vim users already know (`gx`, `]m` `[m`, `<CR>` as the primary action, `g?` for help).

## Screenshots and personal data

Never commit screenshots, recordings or sample data until the maintainer has explicitly approved each file and personal data has been masked: names, phone numbers, message text, profile pictures. This applies to `README.md`, `docs/`, issues and pull requests. Ask first, every time.
