# tuiter

Interactive API explorer for Neovim. Write requests in `.http` files, send
them with one key, read the response in a floating window — with a
Postman-style request sidebar, collections runner, history, environments,
dynamic variables, and JSON pretty-printing. A lightweight
Insomnia/Postman for your editor, written in pure Lua.

## Features

- **`.http` request files** — REST Client format: methods, headers, bodies, named `###` sections, `# @name`
- **Request sidebar** — Postman-style list of every request; run, jump, favorite (`*`), copy-as-curl
- **Collection runner** — `<leader>ia` runs every request in the file and shows a ✓/✗ summary
- **Async requests** — `curl` via `vim.system`, zero plugin dependencies
- **Response window** — status bar (HTTP code · time · size), headers, body; JSON pretty/raw toggle, zoom
- **Dynamic variables** — `{{$timestamp}}`, `{{$uuid}}`, `{{$randomInt}}`, … and response chaining via `{{$body.path.to.field}}`
- **Copy as curl** — Insomnia-style shell-safe curl command, one key
- **History** — every request is stored and replayable from a picker
- **Environments** — `http-client.env.json` / `tuiter.env.json` with `{{var}}` substitution
- **Omni-completion** — `<C-x><C-o>` completes `{{…}}` from request vars, env vars, and dynamic values
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
| `<leader>ih` | Request history (pick & re-run) |
| `<leader>ie` | Select environment |
| `<leader>ir` | Toggle response window |
| `]r` / `[r` | Next / previous request |

In insert mode, `<C-x><C-o>` completes `{{var}}` placeholders (request vars,
env vars, dynamic values).

### Request sidebar (`<leader>il` / `:Tuiter`)

Lists every request in the file — ★ favorites first, method
(color-coded: GET green, POST blue, PUT/PATCH yellow, DELETE red), name,
URL, and the last response status (`[200]`/`[404]` marks).

| Key | Action |
|---|---|
| `<CR>` | Run request (sidebar closes) |
| `g` | Jump to the request in the file |
| `*` | Toggle favorite (persisted) |
| `a` | Run all requests |
| `c` | Copy as curl |
| `?` | Keymap help |
| `q` | Close |

### Run all (`<leader>ia` / `:TuiterRunAll`)

Runs every request in the buffer sequentially and opens a summary float —
✓ green / ✗ red lines with method, name, status, time, size. `<CR>` on a
line jumps to that request in the file.

### Response window

Headers on top, body below. JSON bodies are pretty-printed and
treesitter-highlighted; a status bar shows `tuiter · METHOD URL · HTTP 200
OK · 123ms · 1.2KB · env: dev` (green when ok, red on error/4xx-5xx).

| Key | Action |
|---|---|
| `q` | Close response |
| `t` | Toggle headers window |
| `p` | Toggle pretty / raw JSON body |
| `y` | Copy body to the yank register |
| `c` | Copy as curl command (Insomnia-style) |
| `f` | Save body to a file (`:TuiterSaveBody`) |
| `z` | Zoom: body fills the screen (headers hidden) |
| `r` | Resend the request |
| `?` | Keymap help |

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
| `{{$status}}` | Status code of the last response |
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
| `:TuiterSaveBody` | Save last response body to a file |
| `:TuiterHistory` | Pick a past request and re-run it |
| `:TuiterEnv` | Select environment |
| `:TuiterResponse` | Toggle response window |

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
    keymaps = { -- or false to disable
      run = "<leader>is", list = "<leader>il", run_all = "<leader>ia",
      history = "<leader>ih", env = "<leader>ie", response = "<leader>ir",
    },
    curl = { timeout = 30, insecure = false, max_redirects = 8 },
    env_files = { "http-client.env.json", "tuiter.env.json" },
    default_env = "default",
  },
}
```

## Development

```sh
make test   # headless unit tests + integration test against a local server
make format # stylua
```

Structure:

```
plugin/tuiter.lua      commands + filetype detection
ftplugin/http.lua      buffer keymaps + commentstring + omnifunc
lua/tuiter/init.lua    public API, config, run-all runner
lua/tuiter/parser.lua  .http parsing (pure Lua)
lua/tuiter/client.lua  env/var resolution, dynamic values, curl, response parsing, JSON pretty
lua/tuiter/ui.lua      response windows + request sidebar + run summary
lua/tuiter/history.lua persisted request history
```

## Notes

- Keymaps use the `<leader>i` group — free in LazyVim (shown as a "tuiter"
  which-key group) and never clashes with harpoon (`<leader>h`/`<leader>H`/
  `<leader>1-9`), the test group (`<leader>t*`), or the http-client plugins
  (`<leader>ht`). Change them via `opts.keymaps`.
- History lives in `stdpath("data")/tuiter/history.json`; favorites in
  `stdpath("data")/tuiter/favorites.json`.
