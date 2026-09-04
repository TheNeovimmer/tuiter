# Tuiter Daily-Driver Enhancement Plan

Goal: make tuiter stay-in-nvim Postman replacement for full-time dev.
Zero deps kept: pure Lua + curl, Neovim >=0.10, LazyVim-ready.

## Shared understanding
- workflow: REST+JSON daily, some GraphQL, OAuth2 bearer + cookies, 20-50 reqs/day
- envs: 2-3 envs with $extends + .env layered, secrets redacted
- history: last-first, deduped, replayable
- speed: keyboard-first, <=2 keys for core actions

## P1 Layout - 3-pane toggle
- File: lua/tuiter/ui.lua + lua/tuiter/init.lua windows opts
- Add windows.layout=float|split, response_side=right, sidebar_width=62
- il toggles left sidebar as real split: topleft vsplit + winfixwidth, not float
- Response renders same Body/Headers/Timeline/Tests tabs in botright vsplit when layout=split
- Float stays for quick is send
- ir toggles response split, q closes
- No new files

## P2 Look - dense polished
- Align sidebar cols: star + status + method + name + url
- Reuse TuiterGet/Post/Put/Patch/Delete + TuiterUrl + TuiterOk/Error
- One statusline: METHOD url · code · time · size · env
- Nerd-Font icons with text fallback: check, cross, star
- Grouped ik help: sidebar / response / buffer
- No theme engine

## P3 Speed + Response pane
- Keep: CR send, il sidebar, ia run-all, e env-switch, / filter, J jq, history picker
- History picker last-first with var preview
- Pretty + fold via treesitter, / search, J jq, D diff-vs-last, o open-in-tab
- Truncate >200KB with [show-all] toggle
- Tabs: Body / Headers / Timeline / Tests

## Skipped
- Theme picker, webviews, new deps
- Add when P1-P3 measurably fall short

## Execution order
1. open_floats -> open_response with split branch + sidebar split toggle
2. sidebar align + statusline unify + help group
3. truncate + show-all + history polish
4. tests/run.lua update, README windows docs
