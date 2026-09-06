# tuiter

> API explorer for Neovim. Write requests in `.http` files, send them with
> one key, read the response without leaving your editor.

![Neovim](https://img.shields.io/badge/Neovim-%3E%3D%200.10-green)
![Lua](https://img.shields.io/badge/Pure-Lua-blue)
![Deps](https://img.shields.io/badge/deps-zero-lightgrey)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

⚡ **[Quickstart](#-quickstart)** ·
🔧 **[Configuration](#-configuration)**

## ⚡ Quickstart

Requirements: Neovim ≥ 0.10, `curl` on PATH. Optional: `telescope.nvim`
(pickers), `jq` (the `J` response filter).

```lua
-- ~/.config/nvim/lua/plugins/tuiter.lua (lazy.nvim / LazyVim)
{
  "TheNeovimmer/tuiter",
  branch = "main",
  dependencies = {}, -- zero plugin dependencies: pure Lua + curl
  cmd = { "Tuiter", "TuiterSidebar", "TuiterRun", "TuiterRunAll", "TuiterCancel",
          "TuiterSaveBody", "TuiterHistory", "TuiterEnv", "TuiterVars",
          "TuiterResponse", "TuiterCopyAs", "TuiterStream", "TuiterWatch",
          "TuiterJUnit", "TuiterCI", "TuiterScaffold", "TuiterFormat",
          "TuiterImportPostman", "TuiterImportOpenapi", "TuiterImportCurl",
          "TuiterCollection", "TuiterSnippet" },
  ft = { "http", "graphql" },
  opts = {},
}
```

```lua
require("telescope").load_extension("tuiter") -- :Telescope tuiter <picker>
```

Open a `.http` file, put the cursor on a request, hit `<leader>is`:

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

> Try it locally: `examples/demo.http` works against a public API
> (one request targets a nonexistent endpoint on purpose, so you can see
> how a 404 renders). For offline testing, start `python3 tests/server.py`.

## ✍️ Write — the file *is* the client

REST Client style, many requests per file:

- `### Name` starts a request; a bare `METHOD URL` line also starts one
- First line: `METHOD URL` (e.g. `GET https://…`)
- `Header: value` lines until the first blank line, then the body until the next `###`
- `#` lines are comments; `# @name foo` names the request; `@key = value`
  lines define request-scoped `{{vars}}`

Per-request directives:

| Directive | Effect |
|---|---|
| `# @timeout 5` | curl timeout for this request (must be numeric) |
| `# @no-redirect` | skip `-L` |
| `# @no-log` | don't record in history |
| `# @skip` | exclude from run-all / CI (destructive endpoints) |
| `# @delay 500` | wait N ms before sending (also paces run-all) |
| `# @base URL` | file-level prefix — `GET /users` resolves against it, so dev/staging/prod is a one-line switch (base itself accepts `{{vars}}`) |
| `# @save path` | write the response body to a file on send (`{{vars}}` allowed, relative to the request file) |
| `# @tag a,b` | tags for picker/sidebar filtering (`tag:auth`) |
| `# @cert/# @key/# @proxy/# @insecure` | per-request curl TLS/proxy options |
| `# @stream` | pipe `curl -N` chunks into a live float |
| `# @paginate` + `# @max-pages N` | follow `rel="next"` Link headers, concatenate JSON-array pages |
| `# @before lua` / `# @after lua` | scripts (see [Automate](#-automate)) — aliases `# @lua_pre`, `# @lua_post` |

## 🚀 Send — one key, zero blocking

Requests go out via `curl` over `vim.system` — the editor never blocks.
A braille spinner shows `⠋ GET https://api…` bottom-right while in flight;
every send stamps `✓ 200 · 45ms` / `✗ 404` as virtual text on the request
line, so the file itself shows what passed.

| Key (`.http`, `<leader>i` group) | Action |
|---|---|
| `<leader>is` / `<CR>` | Send request under cursor |
| `<leader>il` | Request browser (Telescope picker, or float sidebar without Telescope) |
| `<leader>ia` | Run all requests, show summary |
| `<leader>ic` | Cancel in-flight requests |
| `<leader>ik` | Keymap help float |
| `<leader>ih` | History (Telescope, or `vim.ui.select`) |
| `<leader>ie` | Environment (Telescope, or `vim.ui.select`) |
| `<leader>iv` | Vars inspector — every `{{var}}`, its value and source |
| `<leader>ir` | Toggle response window |
| `<leader>iq` / `<leader>it` / `<leader>ib` | Command / template / collection browser (with `vim.ui.select` fallback) |
| `]r` / `[r` | Next / previous request |
| `gx` | Open resolved URL in browser |

All `<leader>i` keymaps are configurable via `opts.keymaps`
(`false` disables one, `keymaps = false` disables all). `iq`/`it`/`ib`
are always bound (not part of `opts.keymaps`). In insert mode,
`<C-x><C-o>` completes `{{var}}` placeholders. Every float closes with
`q` **or** `<Esc>`.

### Run all (`<leader>ia` / `:TuiterRunAll`)

Runs every request sequentially and opens a summary float — ✓/✗ lines
with method, status, time, size (⏭ for `# @skip`), failed `# @test`
assertions indented underneath:

| Key | Action |
|---|---|
| `<CR>` | Jump to the request in the file |
| `r` | Re-run only the failed requests |
| `J` | Export JUnit XML |
| `q` / `<Esc>` | Close |

## 🔍 Inspect — response viewer

Body / Headers / Timeline / Tests tabs, colored status badges, a dense
statusline (`METHOD url  200  45ms · 1.2KB · json · dev │ key hints`),
and a per-phase Timeline (DNS, TCP, TLS, TTFB, download).

| Key | Action |
|---|---|
| `1`–`4` / `t` | Tabs / cycle |
| `q` / `<Esc>` | Close |
| `p` | Pretty / raw JSON |
| `y` / `/` | Copy current tab / search |
| `A` | Expand bodies truncated at 200 KB (**split layout only**) |
| `r` / `D` | Resend / diff against previous response |
| `J` | Filter body through `jq` |
| `o` / `z` | Open tab in an editable tab / zoom fullscreen (keeps pretty/tab state) |
| `c` / `C` / `f` | Copy as curl / copy as snippet / save body to file |
| `P` / `V` / `U` | Copy JSONPath (`$.users[0].name`) / JSON value / resolved URL |
| `]k` / `[k` | Next / previous JSON key |
| `gx` | Open URL in browser |

JSON bodies are treesitter-highlighted and foldable; `P`/`V` work in
float mode. Failures are never silent: DNS/refused/timeout shows a
warning toast, the curl error in the Body tab, and a `✗ error` mark.

## 🗂️ Organize — pickers, collections, templates, tags

Browsing is Telescope-first with `vim.ui.select` fallbacks, so tuiter
works with zero plugin dependencies:

| Picker | Command | Key | Without Telescope |
|---|---|---|---|
| Requests | `:Telescope tuiter requests` | `<leader>il` | float sidebar |
| History | `:Telescope tuiter history` | `<leader>ih` | `vim.ui.select` |
| Environments | `:Telescope tuiter env` | `<leader>ie` | `vim.ui.select` |
| Collections | `:Telescope tuiter collections` | `<leader>ib` | `:TuiterCollection list` |
| Templates | `:Telescope tuiter templates` | `<leader>it` | `:TuiterSnippet list` |
| Commands | `:Telescope tuiter commands` | `<leader>iq` | `:Tuiter`-style select |

Request picker actions: `<CR>` send · `<C-o>` go to file ·
`<C-f>` favorite · `<C-s>` copy curl · `<C-c>` copy snippet ·
`<Tab>` multi-select · `<C-a>` run selected. Prompt filters:
`method:GET`, `tag:auth`, `fav:true`. Pickers sort by frequency/recency.

**Float sidebar** (`:TuiterSidebar`, always available): favorites first
with a divider, `tag:` filter, `<CR>` runs while staying open,
`e` switches env, `a` runs all, `c` copies curl.

**Collections** (`*.http.collections/` dirs, git-friendly, optional
`collection.env.json` override):

```vim
:TuiterCollection new my-api    " create my-api.http.collections/
:TuiterCollection add           " add current file (picker)
:TuiterCollection list          " list all (picker)
```

**Templates** (10 built-in: GET/POST/PUT/DELETE, bearer auth,
pagination, GraphQL, health check, login flow):

```vim
:TuiterSnippet list             " built-in + saved
:TuiterSnippet save my-tmpl     " save request under cursor
:TuiterSnippet insert           " insert at cursor ({{cursor}} = landing spot)
```

**Tags**: `# @tag auth,critical` on a request, then `tag:auth` in the
sidebar filter or picker prompt.

## 🤖 Automate — vars, chaining, tests, scripts, auth

Placeholders resolve request vars → env → shell env → dynamic values;
unresolved names stay visible. `<leader>iv` shows each `{{var}}`, its
value, and its source (`request/env/os/dynamic/response`).

| Variable | Meaning |
|---|---|
| `{{$uuid}}` / `{{$guid}}` | random v4 UUID (lower/upper) |
| `{{$timestamp}}` / `{{$isoTimestamp}}` | unix seconds / RFC3339 UTC |
| `{{$randomInt}}` / `{{$randomAlphaNumeric}}` / `{{$randomEmail}}` | randoms |
| `{{$status}}` / `{{$body}}` / `{{$body.a.0.b}}` | last response status / raw body / dotted JSON path |

**Named chaining** — any `# @name login` (or `###` heading) can be
referenced later: `{{login.body.token}}`, `{{login.status}}`.

**Tests** (`# @test`) run on every send and surface in run-all, the
Tests tab, and JUnit exports:

```http
### Create user
# @test status == 201
# @test body.id exists
# @test body.email contains "@"
# @test responseTime < 500
POST https://api.example.com/users
```

Fields: `status`, `responseTime` (ms), `size`, `body`, `body.a.b`
(`body.items.length` works), `headers.<name>`. Operators:
`== != > >= < <= contains matches exists missing`.

**Scripts** (`# @before` / `# @after`): sandboxed Lua with
`request/response/status/body/json()/set_header/set_var/set_env/print`
plus basic string/table/math — no filesystem, network, or `vim.*`
access (see [Security](#-security)):

```http
# @before set_header("X-Request-ID", "{{$uuid}}")
# @after local id = json(body).id; set_env("user_id", tostring(id))
```

**Auth**: `# @auth bearer TOKEN`, `# @auth oauth2
token_url=… client_id=… client_secret=…`, `# @auth refresh …` (auto
refresh-token retry after 401). Tokens cached with expiry in
`stdpath("data")/tuiter/oauth.json`.

## 📦 Ship — watch, CI, import, scaffold

- `:TuiterWatch [sec]` — re-run under cursor every N seconds, notify on change (toggle to stop)
- `:TuiterCI` — headless run-all, writes `tuiter-junit.xml`, exits non-zero on failure: `nvim --headless -c 'edit api.http' -c TuiterCI`
- `:TuiterJUnit [path]` — export last run as JUnit **XML**
- `:TuiterImportPostman / :TuiterImportOpenapi / :TuiterImportCurl` — convert collections, specs, DevTools/`gh api -i` curl commands to `.http`
- `:TuiterScaffold` — example buffer · `:TuiterFormat` — pretty-print request JSON

## ⌨️ Commands

| Command | Action |
|---|---|
| `:Tuiter` | Request browser (picker, or float sidebar) |
| `:TuiterSidebar` | Always the floating sidebar |
| `:TuiterRun [lnum]` / `:TuiterRunAll` / `:TuiterCancel` | Send / run all / cancel |
| `:TuiterHistory` / `:TuiterEnv` / `:TuiterVars` | History / env / vars inspector |
| `:TuiterResponse` / `:TuiterSaveBody` | Toggle response / save body |
| `:TuiterCopyAs [curl\|python\|js\|ts\|go\|rust\|php\|graphql]` | Copy as snippet (no arg = picker) |
| `:TuiterStream` / `:TuiterWatch [sec]` | SSE stream / poll |
| `:TuiterJUnit [path]` / `:TuiterCI` | JUnit XML export / headless CI run |
| `:TuiterScaffold` / `:TuiterFormat` | Example buffer / format JSON |
| `:TuiterImportPostman/Openapi/Curl` | Import converters |
| `:TuiterCollection [new\|add\|list]` / `:TuiterSnippet [list\|save\|insert]` | Collections / templates |

## 🌍 Environments

`http-client.env.json` / `tuiter.env.json`, searched upward from the
request file; `collection.env.json` wins inside a collection; `.env`
(vars, `export` not supported) layers underneath. `"$extends"` merges a
base env (child wins, cycles ignored). Files hot-reload; a **broken
JSON file warns once with the parse error** instead of silently leaving
`{{vars}}` unresolved.

```json
{ "base": { "host": "https://api.example.com" },
  "dev":  { "$extends": "base", "token": "dev-token" } }
```

History redacts `Authorization`/`Cookie`/API-key headers; per-project
cookie jars persist logins automatically.

## 🔧 Configuration

```lua
{
  opts = {
    keymaps = { -- false disables one key; keymaps = false disables all
      run = "<leader>is", list = "<leader>il", run_all = "<leader>ia",
      cancel = "<leader>ic", help = "<leader>ik", history = "<leader>ih",
      env = "<leader>ie", response = "<leader>ir", vars = "<leader>iv",
      browser = "gx",
    },
    icons = "auto", -- "auto" (portable unicode) | "nerd" | "ascii"
    curl = { timeout = 30, insecure = false, max_redirects = 8,
             cookie_jar = true, compressed = true },
    env_files = { "http-client.env.json", "tuiter.env.json" },
    default_env = "default",
    run_all = { concurrency = 1, delay = 150 },
    windows = {
      layout = "float", -- "float" (default) or "split" (3-pane: file/sidebar/response)
      width = 120, max_height = 40, sidebar_width = 62,
    },
  },
}
```

**Split layout** keeps `[.http] [sidebar] [response]` visible while you
edit (`<leader>ir` toggles the response pane). Statusline for lualine:

```lua
{ function() return require("tuiter").statusline() end,
  cond = function() return require("tuiter").statusline() ~= "" end }
-- renders:  env: dev (tuiter.env.json) · HTTP 200
```

## 🔒 Security

- `# @before`/`# @after` scripts run sandboxed (helpers + safe stdlib
  only). Still, **never run `.http` files from untrusted sources** —
  the request itself can exfiltrate (URLs, headers, bodies go to the network).
- Secrets: history drops auth/cookie/API-key headers and caps stored
  bodies at 16 KB, but tokens in URLs/bodies/env files are plaintext —
  keep env files out of git or use git-crypt/sops.
- `# @insecure` (`curl -k`) commits silently — prefer `# @cert`/`# @key`.

## 🩺 Health & troubleshooting

`:checkhealth tuiter` verifies Neovim, curl, writable data dirs (and
notes missing `jq`).

| Symptom | Fix |
|---|---|
| `⚠ unresolved` everywhere | broken env JSON — look for the parse-error warning naming the file |
| `no request under cursor` | cursor must be on/inside a `METHOD URL` block |
| `E5108`/ENOENT at send | `curl` missing from PATH |
| Picker keys do nothing | Telescope absent — `vim.ui.select` fallbacks apply; install telescope.nvim for full pickers |
| `A` does nothing | body truncation/expand is split-layout only |

## 🛠️ Development

```sh
make test   # headless unit + integration + e2e (local server on :8999)
make smoke  # real-config LazyVim smoke test (needs your ~/.config/nvim)
```

```
plugin/tuiter.lua        commands + filetype detection
ftplugin/http.lua        buffer keymaps, omnifunc, diagnostics, K-hover, gd
ftplugin/graphql.lua     same for .graphql buffers
lua/tuiter/init.lua      public API, config, run-all, watch/JUnit/CI/import
lua/tuiter/parser.lua    .http parsing + validation (pure Lua)
lua/tuiter/graphql.lua   .graphql parsing (pure Lua)
lua/tuiter/client.lua    vars/env, curl, tests, chaining, dotenv, paginate, stream, scripts
lua/tuiter/auth.lua      OAuth2/bearer token cache
lua/tuiter/codegen.lua   curl/python/js/ts/go/rust/php/graphql snippets
lua/tuiter/import.lua    Postman + OpenAPI → .http (pure functions)
lua/tuiter/ui.lua        floats/splits, sidebar, summary, spinner, badges
lua/tuiter/history.lua   persisted history (secrets redacted, bodies capped)
lua/tuiter/pickers.lua   6 Telescope pickers + sorting, multi-select, favorites
lua/tuiter/collections.lua + templates.lua   collections + templates
lua/tuiter/icons.lua     nerd/unicode/ascii glyph sets
lua/telescope/_extensions/tuiter.lua         :Telescope tuiter <picker>
syntax/http.vim          method/URL/header/JSON highlighting
```

```lua
require("telescope").load_extension("tuiter")
-- :Telescope tuiter requests | history | env | collections | templates | commands
```

## 📝 Notes

- Keymaps live under `<leader>i` (LazyVim shows a which-key group);
  no clash with harpoon or `<leader>t*`.
- Data lives in `stdpath("data")/tuiter/`: `history.json`
  (+`.corrupt.bak` quarantine), `favorites.json`, `stats.json`,
  per-project `cookies/`, `oauth.json`.
