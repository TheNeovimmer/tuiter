# tuiter

[![CI](https://github.com/TheNeovimmer/tuiter/actions/workflows/ci.yml/badge.svg)](https://github.com/TheNeovimmer/tuiter/actions/workflows/ci.yml)

Interactive API explorer for Neovim. Write requests in `.http` files, send
them with one key, read the response in a floating window — with a
Postman-style request sidebar, collections runner, history, environments,
dynamic variables, and JSON pretty-printing. A lightweight
Insomnia/Postman for your editor, written in pure Lua.

## Features

- **`.http` request files** — REST Client format: methods, headers, bodies, named `###` sections, `# @name`
- **Insomnia-style composer** — methods color-coded in the file itself, blue URLs, section titles, `@var`s
- **Request sidebar** — Postman-style list of every request; run, jump, favorite (`*`), filter (`/`), switch env (`e`), copy-as-curl
- **Collection runner** — `<leader>ia` runs every request in the file and shows a ✓/✗ summary
- **Async requests** — `curl` via `vim.system`, zero plugin dependencies; cancel hanging requests with `<leader>ic`
- **Response viewer with tabs** — Body / Headers / Timeline, like Insomnia's response pane
- **Timeline tab** — per-phase timing breakdown (DNS, TCP, TLS, TTFB, download) from curl
- **Status bar** — HTTP code · time · size · env, green/red, in every response window
- **Dynamic variables** — `{{$timestamp}}`, `{{$uuid}}`, `{{$randomInt}}`, … and response chaining via `{{$body.path.to.field}}`
- **Copy as curl / code snippets** — Insomnia-style shell-safe curl command, plus `:TuiterCopyAs python|js|go` for real code
- **GraphQL files** — `.graphql`/`.gql` buffers: each operation becomes a POST with `{"query", "variables"}` from `# @url` / `# @variables`
- **Form bodies** — `multipart/form-data` (`-F`) and `application/x-www-form-urlencoded` (`--data-urlencode`) are sent as proper fields
- **Cookie jar** — per-project persisted cookies (`-c`/`-b`), so login → follow-up requests just work
- **History** — every request is stored and replayable from a picker (consecutive duplicates collapse)
- **Environments** — `http-client.env.json` / `tuiter.env.json` with `{{var}}` substitution
- **Omni-completion** — `<C-x><C-o>` completes `{{…}}` from request vars, env vars, and dynamic values
- **Diagnostics** — malformed requests (missing URL, bad scheme, header/body mistakes) show as LSP-style warnings while you edit
- **LazyVim-ready** — lazy-loaded, which-key descriptions + group, works with any picker via `vim.ui.select`

## Requirements

- Neovim >= 0.10 (uses `vim.system`, window titles, `vim.json`)
- `curl` on PATH

## Installation (LazyVim / lazy.nvim)

```lua
{
  dir = "~/path/to/tuiter", -- or "user/tuiter" once published
  cmd = { "Tuiter", "TuiterRun", "TuiterRunAll", "TuiterSaveBody", "TuiterHistory", "TuiterEnv", "TuiterResponse" },
  ft = "http",
  opts = {},
}
```

## Usage

Open a `.http` file and press `<leader>il` for the request sidebar, or put
the cursor on a request and hit `<leader>is`:

```http
### Get users
GET https://jsonplaceholder.typicode.com/users
Accept: application/json

### Create user
POST https://jsonplaceholder.typicode.com/users
Content-Type: application/json

{
  "name": "ada"
}
```

> Try it locally: `examples/demo.http` works against a public API. For
> offline testing, start `python3 tests/server.py` and run the last three
> requests. One demo request hits a deliberately nonexistent endpoint so
> you can see how a 404 looks — it means the request reached the server
> fine, the URL just doesn't exist (not a network error).

### Request file format

REST Client style, many requests per file:

- `### Name` starts a new request (optional name); a bare `METHOD URL` line
  also starts one without a name
- First line: `METHOD URL` — `GET` is implied when the method is omitted
- `Header: value` lines until the first blank line
- After the blank line, everything until the next `###` is the request body
- `#` lines are comments; `# @name foo` names the request (REST Client syntax)
- Per-request directives: `# @timeout 5` (overrides `curl.timeout`), `# @no-redirect`
  (skip `-L`), `# @no-log` (don't record this request in history)
- `@name = value` lines define request-scoped variables (usable as `{{name}}`)

```http
### Auth
# @name login
@token = abc123
POST https://api.example.com/login
Authorization: Bearer {{token}}
Content-Type: application/json

{"user": "ada"}
```

### Keymaps (`.http` files, `<leader>i` group)

| Key | Action |
|---|---|
| `<leader>is` | Send request under cursor |
| `<leader>il` | Request sidebar (like Postman's collection list) |
| `<leader>ia` | Run all requests in the file, show summary |
| `<leader>ic` | Cancel in-flight requests |
| `<leader>ik` | Keymap help float |
| `<leader>ih` | Request history (pick & re-run) |
| `<leader>ie` | Select environment |
| `<leader>ir` | Toggle response window |
| `]r` / `[r` | Next / previous request |

All keymaps are configurable — see [Configuration](#configuration). To
skip one (or all), set it to `false` / pass `keymaps = false`.

In insert mode, `<C-x><C-o>` completes `{{var}}` placeholders (request vars,
env vars, dynamic values).

### Request sidebar (`<leader>il` / `:Tuiter`)

Lists every request in the file — ★ favorites first, method
(color-coded: GET green, POST blue, PUT/PATCH yellow, DELETE red), name,
URL, and the last response status (`[200]`/`[404]` marks).

| Key | Action |
|---|---|
| `<CR>` | Run request (sidebar stays open — response opens to its right) |
| `g` | Jump to the request in the file |
| `*` | Toggle favorite (persisted) |
| `/` | Filter requests by name/URL/method (Insomnia-style search) |
| `e` | Switch environment (sidebar re-renders) |
| `a` | Run all requests |
| `c` | Copy as curl |
| `?` | Keymap help |
| `q` | Close |

### Run all (`<leader>ia` / `:TuiterRunAll`)

Runs every request in the buffer sequentially and opens a summary float —
✓ green / ✗ red lines with method, name, status, time, size. `<CR>` on a
line jumps to that request in the file.

### Response window

Insomnia-style: a tab bar (Body | Headers | Timeline) over the response,
with a status bar showing `tuiter · METHOD URL · HTTP 200 OK · 123ms ·
1.2KB · env: dev` (green when ok, red on error/4xx-5xx). The tab bar shows
HTTP status · time · size on the right.

| Key | Action |
|---|---|
| `1` / `2` / `3` | Body / Headers / Timeline tab |
| `t` | Cycle tabs |
| `q` | Close response |
| `p` | Toggle pretty / raw JSON body |
| `y` | Copy current tab (body, headers, or timeline) |
| `c` | Copy as curl command (Insomnia-style) |
| `f` | Save body to a file (`:TuiterSaveBody`) |
| `z` | Zoom: response fills the screen (tab bar hidden) |
| `r` | Resend the request |
| `?` | Keymap help |

- **Body tab**: JSON is pretty-printed, treesitter-highlighted and
  foldable (`zc`/`zo`); HTML/XML/CSS/JS bodies get their filetype syntax too
- **Headers tab**: response headers with keys highlighted
- **Timeline tab**: per-phase timings — DNS lookup, TCP connect, TLS
  handshake, request sent, waiting (TTFB), download, total — plus size,
  redirects, protocol and content type

### Dynamic variables & response chaining

Placeholders are resolved at send time, in order: request vars → env vars →
shell env → dynamic values. Unresolved names stay visible so you can see
what's missing.

| Variable | Meaning |
|---|---|
| `{{$timestamp}}` | Unix seconds |
| `{{$uuid}}` | Random v4 UUID (lowercase) |
| `{{$guid}}` | Random v4 UUID (uppercase) |
| `{{$randomInt}}` | Random integer 0–10⁶ |
| `{{$isoTimestamp}}` | RFC3339 UTC timestamp (`2024-01-01T00:00:00Z`) |
| `{{$randomAlphaNumeric}}` | 16 random alphanumeric characters |
| `{{$randomEmail}}` | Random `…@example.com` address |
| `{{$status}}` | Status code of the last response |
| `{{$body}}` | Raw (unparsed) last response body |
| `{{$body.a.b.0.c}}` | Dotted path into the last response's JSON body (array indexes are 0-based, like Insomnia) |

```http
### Login — store a token
POST https://api.example.com/login
Content-Type: application/json

{"user": "ada"}

### Use the token from the login response
GET https://api.example.com/me
Authorization: Bearer {{$body.token}}
```

> Responses from single runs (sidebar `<CR>`, `<leader>is`) feed `{{$body.*}}`;
> the collection runner also records each response, so later requests can
> chain off earlier ones.

### Insomnia / Postman mapping

| Insomnia | tuiter |
|---|---|
| Send (`Ctrl+Enter`) | `<leader>is` or `<CR>` in sidebar |
| Collection sidebar | `<leader>il` |
| Environment selector | `<leader>ie` |
| Recent requests | `<leader>ih` |
| Copy as curl | `c` in response window |
| Request chain (`response.body…`) | `{{$body.path}}` |
| Dynamic values (`$timestamp`…) | `{{$timestamp}}` etc. |

### Commands

| Command | Action |
|---|---|
| `:Tuiter` | Toggle request sidebar |
| `:TuiterRun [lnum]` | Send request under cursor |
| `:TuiterRunAll` | Run all requests, show summary |
| `:TuiterCancel` | Cancel in-flight requests |
| `:TuiterSaveBody` | Save last response body to a file |
| `:TuiterHistory` | Pick a past request and re-run it |
| `:TuiterEnv` | Select environment |
| `:TuiterResponse` | Toggle response window |
| `:TuiterCopyAs [curl\|python\|js\|go]` | Copy the request under the cursor as a code snippet (no arg = picker) |

## GraphQL support

`.graphql` / `.gql` files get the same tuiter keymaps (send under cursor,
sidebar, run all, completion). The endpoint comes from a `# @url` directive;
every `query` / `mutation` / `subscription` operation becomes a POST with a
JSON body `{"query": "<operation>", "variables": <# @variables or null>}`.
`# @variables` attaches to the next operation and supports `{{var}}`:

```graphql
# @url http://localhost:4000/graphql
# @variables {"userId": "{{$body.user.id}}"}

query GetUser($id: ID!) {
  user(id: $id) { name }
}
```

## Form bodies & cookies

- `Content-Type: multipart/form-data` + a body of `key=value` lines → sent
  as `curl -F` fields (file uploads work too: `key=@path/to/file`). Raw
  boundary syntax (`--boundary` lines) is sent as-is.
- `Content-Type: application/x-www-form-urlencoded` + a body of `key=value`
  lines (no `&`) → sent as `curl --data-urlencode` fields, so values are
  encoded for you. Anything else goes through as a raw body.
- Cookies: `curl.cookie_jar = true` (default) keeps a per-project cookie jar
  under `stdpath("data")/tuiter/cookies/`, so a login request's `Set-Cookie`
  is sent on follow-up requests automatically. Disable with
  `curl = { cookie_jar = false }`.

## Statusline integration

`require("tuiter").statusline()` returns `env: dev · HTTP 200` for the
current environment and last response — drop it into lualine or a custom
statusline:

```lua
-- lualine
{ "tuiter.statusline", cond = function() return require("tuiter").statusline() ~= "" end }
```

## How it works

```
<leader>is on a .http file
      │
      ▼
parser.lua        parse buffer → request spec {method, url, headers, body, vars}
      │
      ▼
client.lua        substitute {{vars}} + {{$dynamic}} → curl_args() → vim.system(curl, async)
      │
      ▼
client.lua        parse_response() splits headers/body + status/time/size
      │  (vim.schedule — curl callbacks fire in a fast-event context,
      │   deferred to the main loop before touching windows)
      ▼
ui.lua            show(): pretty-print JSON → treesitter json → floats + status bar
history.lua       append to stdpath("data")/tuiter/history.json
```

- Requests go out via `curl` over `vim.system` — never blocks the editor
  (`--compressed` handles gzip/deflate/br transparently; responses are parsed
  per-request with a 9-field `-w` timing marker)
- The parser is pure Lua (no `vim.*`), so it runs in plain headless tests
- Everything is lazy-loaded: the module chain only loads when you use a
  `Tuiter*` command or open a `.http` file

## Public API

```lua
require("tuiter").setup(opts)            -- configure (idempotent)
require("tuiter").run({ buf, lnum })     -- send request under cursor
require("tuiter").run_all({ buf })       -- run every request, show summary
require("tuiter").resend(spec)           -- send a spec directly
require("tuiter").sidebar()              -- toggle request sidebar
require("tuiter").history()              -- pick from history & re-run
require("tuiter").select_env({ cwd })    -- choose environment
require("tuiter").toggle_response()      -- show/hide response window
require("tuiter").close_response()
require("tuiter").copy_as("python")       -- copy snippet for the request under cursor
require("tuiter").statusline()           -- "env: dev · HTTP 200" for lualine
```

## Environment variables

Placeholders `{{name}}` are resolved in order: request vars (`@name = value`),
the selected environment, then shell env. Unresolved names stay visible.

```json
// http-client.env.json or tuiter.env.json (same format)
{
  "dev":  { "token": "dev-token" },
  "prod": { "token": "prod-token" }
}
```

The file is searched upward from the request file's directory. The
`default` environment (or first key) is picked automatically on first use;
switch with `:TuiterEnv` or `<leader>ie`.

## Configuration

```lua
{
  opts = {
    keymaps = { -- false disables that key; keymaps = false disables all
      run = "<leader>is", list = "<leader>il", run_all = "<leader>ia",
      cancel = "<leader>ic", help = "<leader>ik",
      history = "<leader>ih", env = "<leader>ie", response = "<leader>ir",
    },
    curl = { timeout = 30, insecure = false, max_redirects = 8, cookie_jar = true, compressed = true },
    env_files = { "http-client.env.json", "tuiter.env.json" },
    default_env = "default",
  },
}
```

Example — move everything off `<leader>i` and drop the ones you don't
want: `opts = { keymaps = { run = "<leader>xr", list = "<leader>xl", cancel = false } }`.

## Development

```sh
make test   # headless unit + integration + e2e tests (local server on :8999)
make smoke  # real-config LazyVim smoke test (needs your ~/.config/nvim)
make format # stylua
make lint   # stylua --check
```

Structure:

```
plugin/tuiter.lua      commands + filetype detection
ftplugin/http.lua      buffer keymaps + commentstring + omnifunc + diagnostics
ftplugin/graphql.lua   same for .graphql buffers
lua/tuiter/init.lua    public API, config, run-all runner
lua/tuiter/parser.lua  .http parsing + validation (pure Lua)
lua/tuiter/graphql.lua .graphql parsing (pure Lua)
lua/tuiter/client.lua  env/var resolution, dynamic values, curl, response parsing, JSON pretty
lua/tuiter/codegen.lua curl/python/js/go snippet generation
lua/tuiter/ui.lua      response windows + request sidebar + run summary
lua/tuiter/history.lua persisted request history
```

## Notes

- Keymaps use the `<leader>i` group — free in LazyVim (shown as a "tuiter"
  which-key group) and never clashes with harpoon (`<leader>h`/`<leader>H`/
  `<leader>1-9`), the test group (`<leader>t*`), or the http-client plugins
  (`<leader>ht`). Change them via `opts.keymaps`.
- History lives in `stdpath("data")/tuiter/history.json`; favorites in
  `stdpath("data")/tuiter/favorites.json`; cookies per project in
  `stdpath("data")/tuiter/cookies/`.
- CI runs `make test` + stylua on every push (`.github/workflows/ci.yml`).
