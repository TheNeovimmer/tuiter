tuiter
=====

API explorer for Neovim. Write requests in `.http` files, send them with
one key, read the response in a floating window — with a request sidebar,
collections runner, history, environments, dynamic variables, and JSON
pretty-printing. Pure Lua, zero deps, Neovim-native.

## Features

- **`.http` request files** — REST Client format: methods, headers, bodies, named `###` sections, `# @name`
- **Syntax highlighting** — methods color-coded (GET green, POST blue, PUT/PATCH yellow, DELETE red), blue URLs, section titles, `@var`s, JSON bodies, `{{variables}}` — via `syntax/http.vim`
- **Loading spinner** — animated braille spinner shows `⠋ GET https://api…` while a request is in flight
- **Inline result marks** — every send stamps `✓ 200 · 45ms` / `✗ 404` as virtual text on the request line, so the file itself shows what passed and what didn't
- **Request sidebar** — list of every request; run, jump, favorite (`*`), filter (`/`), switch env (`e`), copy-as-curl; favorites separated from the rest with a divider
- **Collection runner** — `<leader>ia` runs every request in the file and shows a ✓/✗ summary; `# @skip` requests are excluded (handy for destructive endpoints)
- **Health check** — `:checkhealth tuiter` verifies Neovim, curl and the data/cookie dirs
- **Async requests** — `curl` via `vim.system`, zero plugin dependencies; cancel hanging requests with `<leader>ic`
- **Response viewer with tabs** — Body / Headers / Timeline / Tests, with colored status badges (` 200 ` green, ` 404 ` red) and method-colored tab bar
- **Timeline tab** — per-phase timing breakdown (DNS, TCP, TLS, TTFB, download) from curl
- **Status bar** — method (color-coded) · url · status badge · time · size · encoding · content-type · env · key hints — a dense, sectioned statusline
- **Pre/post request scripts** — `# @before` / `# @after` Lua snippets that run before/after each request; can modify headers, read response, set env vars
- **Dynamic variables** — `{{$timestamp}}`, `{{$uuid}}`, `{{$randomInt}}`, … and response chaining via `{{$body.path.to.field}}`
- **Named request chaining** — reference any earlier request by name: `{{login.body.token}}`, `{{login.status}}`
- **Assertions / tests** — `# @test status == 200` per request, checked in the run summary + exported to JUnit JSON
- **OAuth2 + bearer auth** — `# @auth bearer TOKEN`, `# @auth oauth2 client_credentials` and `refresh` flows with token caching
- **Streaming (SSE)** — `# @stream` pipes curl -N chunks into a live float
- **Pagination** — `# @paginate` follows `rel="next"` Link headers and concatenates array pages
- **Copy as curl / code snippets** — shell-safe curl plus `:TuiterCopyAs python|js|ts|go|rust|php|graphql`
- **Import** — convert Postman collections, OpenAPI specs, and curl commands
  (DevTools / docs / `gh api -i`) to `.http` via `:TuiterImportPostman` /
  `:TuiterImportOpenapi` / `:TuiterImportCurl`
- **`.env` support** — `.env` vars are layered under the selected JSON environment
- **Base URLs** — `# @base https://api.example.com/v1` at the top of a file; relative
  URLs (`GET /users`) resolve against it, so switching dev/staging/prod is one line
- **Environment inheritance** — a `"$extends": "base"` key makes dev/prod/staging
  share a base environment (e.g. dev inherits from base)
- **Response export** — `# @save path.json` writes the response body to a file on
  every send / run-all (paths support `{{vars}}`)
- **Requester tooling** — `:TuiterWatch` healthcheck, `:TuiterCI` headless run-all with exit code + JUnit, `:TuiterJUnit`, `:TuiterFormat`, `:TuiterScaffold`
- **Response tooling** — diff against previous (`D`), jq filter (`J`), open in a tab (`o`), JSON key navigation (`]k`/`[k`), search (`/`), expand truncated bodies (`A`), and a Tests tab (`4`)
- **Picker integration** — Telescope extension (`history` / `requests` / `env`) plus `vim.ui.select` (LazyVim → snacks picker)
- **Per-request curl directives** — `# @cert`, `# @key`, `# @proxy`, `# @insecure`
- **Secret redaction** — Authorization / Cookie / API-key header values are never written to history
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
-- ~/.config/nvim/lua/plugins/tuiter.lua (LazyVim) or any lazy.nvim spec
{
  "TheNeovimmer/tuiter",
  branch = "main",
  dependencies = {}, -- zero plugin dependencies: pure Lua + curl only
  cmd = { "Tuiter", "TuiterRun", "TuiterRunAll", "TuiterCancel", "TuiterSaveBody", "TuiterHistory", "TuiterEnv", "TuiterResponse", "TuiterCopyAs", "TuiterStream", "TuiterWatch", "TuiterJUnit", "TuiterCI", "TuiterScaffold", "TuiterFormat", "TuiterImportPostman", "TuiterImportOpenapi", "TuiterImportCurl" },
  ft = { "http", "graphql" },
  opts = {},
}
```

All plugins load lazily: `cmd` triggers on any `Tuiter*` command, `ft` on
opening a `.http` / `.graphql` file. Change the keymaps or skip them via
`opts` — see [Configuration](#configuration).

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
  (skip `-L`), `# @no-log` (don't record this request in history), `# @skip`
  (exclude from run-all / CI — destructive or flaky requests), `# @delay 500`
  (wait N ms before sending; also paces run-all), `# @base URL` (file-level URL
  prefix — see below), `# @save path` (write the response body to a file on send)
- Pre/post scripts: `# @before <lua-code>` runs before the request is sent
  (can modify headers, vars via `set_header()`, `set_var()`, `set_env()`),
  `# @after <lua-code>` runs after the response arrives (can inspect `response`,
  `status`, `body`, `json()`). Aliases: `# @lua_pre`, `# @lua_post`.
- `# @base https://api.example.com/v1` at the top of the file (or above a
  request) lets later requests use relative URLs: `GET /users` becomes
  `https://api.example.com/v1/users` at send time. The base itself can contain
  `{{vars}}`. Change the base line and every request in the file follows — no
  more find-and-replace when you switch between dev and prod.
- `# @save out/{{$timestamp}}.json` writes the response body to a file after the
  request lands (send, sidebar `<CR>` or run-all). The path supports `{{vars}}`
  and resolves relative to the request file's directory; failed requests are
  not exported. Handy for dumping API output into a folder you can diff/watch.
- `@name = value` lines define request-scoped variables (usable as `{{name}}`)
- `multipart/form-data` bodies accept `key=@path` file fields — relative
  paths resolve against the request file's directory, and `{{vars}}` work
  inside them (see `examples/upload.http`)

```http
### Auth
# @name login
@token = abc123
POST https://api.example.com/login
Authorization: Bearer {{token}}
Content-Type: application/json

{"user": "ada"}
```

### Pre/post scripts

Run Lua code before or after a request — useful for dynamic auth, logging,
or chaining logic that the directive system can't express:

```http
### Create user and store the ID
# @before set_header("X-Request-ID", "{{$uuid}}")
# @after local id = json(body).id; set_env("user_id", tostring(id))
POST https://api.example.com/users
Content-Type: application/json

{"name": "ada"}
```

Available in the script environment: `request`, `response`, `status`, `body`,
`json(str)`, `set_header(k, v)`, `set_var(k, v)`, `set_env(k, v)`, `print()`.
Scripts run in a sandboxed `load()` — no filesystem or network access.

### Keymaps (`.http` files, `<leader>i` group)

| Key | Action |
|---|---|
| `<leader>is` / `<CR>` | Send request under cursor |
| `<leader>il` | Request sidebar |
| `<leader>ia` | Run all requests in the file, show summary |
| `<leader>ic` | Cancel in-flight requests |
| `<leader>ik` | Keymap help float |
| `<leader>ih` | Request history (pick & re-run) |
| `<leader>ie` | Select environment |
| `<leader>iv` | Show resolved values of every `{{var}}` in the request (vars inspector) |
| `<leader>ir` | Toggle response window |
| `]r` / `[r` | Next / previous request |
| `gx` | Open the request URL in your browser (`vim.ui.open`, vars resolved) |

All keymaps are configurable — see [Configuration](#configuration). To
skip one (or all), set it to `false` / pass `keymaps = false`.

In insert mode, `<C-x><C-o>` completes `{{var}}` placeholders (request vars,
env vars, dynamic values).

### Request sidebar (`<leader>il` / `:Tuiter`)

Lists every request in the file — ★ favorites first (separated by a
divider), method (color-coded: GET green, POST blue, PUT/PATCH yellow,
DELETE red), name, URL, and the last response status with icons
(` ✓ 200 45ms` / ` ✗ 12ms` / ` ✗ error` marks).

| Key | Action |
|---|---|
| `<CR>` | Run request (sidebar stays open — response opens to its right) |
| `g` | Jump to the request in the file |
| `*` | Toggle favorite (persisted) |
| `/` | Filter requests by name/URL/method |
| `e` | Switch environment (sidebar re-renders) |
| `a` | Run all requests |
| `c` | Copy as curl |
| `?` | Keymap help |
| `q` | Close |

### Run all (`<leader>ia` / `:TuiterRunAll`)

Runs every request in the buffer sequentially and opens a summary float —
✓ green / ✗ red lines with method, name, status, time, size (⏭ grey lines
for `# @skip` requests, which are not sent). `<CR>` on a line jumps to
that request in the file. Requests also stamp their result as inline
virtual text in the buffer (`✓ 200 · 45ms` / `✗ 404 · 12ms`).

### Response window

The tab bar sits above the response: `● GET  body │ headers │ timeline │ tests    200  45ms · 1.2KB`, with a statusline showing `METHOD url  200  45ms · 1.2KB · json · dev │ q quit │ 1-4 tabs │ p pretty │ y copy │ r retry │ D diff`
(method color-coded, status badge with colored background). In float mode
the tab bar is a separate window; in split mode it is the first line of the
response buffer.

While a request is in flight, a loading spinner floats at the bottom-right
showing `⠋ GET https://api…` with an animated braille character. The
spinner is dismissed automatically when the response arrives. Request
failures (DNS, connection refused, timeout, cancel) are never silent: a
warning toast fires, the status bar and Body tab show the curl error
instead of an empty body, and the request line gets a `✗ error` mark.

Response bodies over 200KB are truncated in the body tab with a
`[show-all]` note — press `A` to expand, `p` (pretty/raw) or `o` (open in tab) to see the
full content.

| Key | Action |
|---|---|
| `1` / `2` / `3` / `4` | Body / Headers / Timeline / Tests tab |
| `t` | Cycle tabs |
| `q` | Close response |
| `p` | Toggle pretty / raw JSON body |
| `y` | Copy current tab (body, headers, timeline, or tests) |
| `/` | Search in response (vim `/`) |
| `A` | Toggle show-all for truncated >200KB bodies |
| `c` | Copy as curl command |
| `C` | Copy as code snippet (picker) |
| `f` | Save body to a file (`:TuiterSaveBody`) |
| `z` | Zoom: response fills the screen (tab bar hidden) |
| `r` | Resend the request |
| `D` | Diff against the previous response |
| `J` | Filter the body through `jq` (requires jq on PATH) |
| `o` | Open the current tab in an editable new tab |
| `]k` / `[k` | Jump to next / previous JSON key (Body tab) |
| `P` | Copy the JSONPath of the node under the cursor (`$.users[0].name`) |
| `V` | Copy the JSON value at the cursor (scalar, or the whole pretty subtree) |
| `U` | Copy the resolved request URL (method + URL, vars substituted) |
| `gx` | Open the request URL in your browser |
| `?` | Keymap help |

- **Body tab**: JSON is pretty-printed, treesitter-highlighted and
  foldable (`zc`/`zo`), with line numbers — `P` copies the JSONPath of the
  node under the cursor (`$.users[0].name`), `V` copies its value (or the
  whole pretty subtree for containers); HTML/XML/CSS/JS bodies get their
  filetype syntax too
- **Headers tab**: response headers with keys highlighted
- **Timeline tab**: per-phase timings — DNS lookup, TCP connect, TLS
  handshake, request sent, waiting (TTFB), download, total — plus size,
  redirects, protocol and content type

### Dynamic variables & response chaining

Placeholders are resolved at send time, in order: request vars → env vars →
shell env → dynamic values. Unresolved names stay visible so you can see
what's missing.

`<leader>iv` (or `:TuiterVars`) opens the **vars inspector** — every
`{{var}}` used by the request under the cursor, its resolved value, and
which source it came from (`request` / `env` / `os` / `dynamic` /
`response`), with `⚠ unresolved` for anything that won't resolve. It's the
fastest way to answer "what did this env actually substitute?" before you
send.

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
| `{{$body.a.b.0.c}}` | Dotted path into the last response's JSON body (array indexes are 0-based) |

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

### Named request chaining

Any request with a name (`# @name login` or a `###` heading) can be referenced
from later requests — not just the last one:

```http
### Login
# @name login
POST https://api.example.com/login
Content-Type: application/json

{"user": "ada"}

### Use the token from the LOGIN response (not the last response)
GET https://api.example.com/me
Authorization: Bearer {{login.body.token}}
```

Supported: `{{name.body}}`, `{{name.status}}`, `{{name.body.path.to.field}}`
(0-based array indexes).

### Assertions (`# @test`)

Write tests next to a request; they run on every send and are checked in the
run-all summary, the response window's **Tests tab** (`4`), and JUnit exports:

```http
### Create user
# @test status == 201
# @test body.id exists
# @test body.email contains "@"
# @test responseTime < 500
POST https://api.example.com/users
Content-Type: application/json

{"email": "ada@example.com"}
```

Supported: `status`, `responseTime` (ms), `size`, `body`, `body.path.to.field`
(with `body.items.length`), `headers.<name>`. Operators: `== != > >= < <=`,
`contains`, `matches`, `exists`, `missing`. RHS: numbers, quoted strings,
`true`/`false`/`null`.

`<leader>ia` shows ✓/✗ per assertion. `:TuiterJUnit [path]` exports the last
run as JUnit XML (default `tuiter-junit.xml`); `:TuiterCI` runs all requests
headlessly and exits non-zero on failure for CI pipelines:

```sh
nvim --headless -c 'edit api.http' -c TuiterCI
```

### OAuth2 & bearer auth

```http
### Static token
# @auth bearer eyJhbGciOi...
GET https://api.example.com/me

### Client credentials
# @auth oauth2 token_url=https://auth.example.com/token client_id=abc client_secret=def scope=api.read
GET https://api.example.com/private

### Refresh token (auto-refetches after 401)
# @auth refresh token_url=https://auth.example.com/token client_id=abc client_secret=def refresh_token=rt1
GET https://api.example.com/private
```

Tokens are cached (with expiry) in `stdpath("data")/tuiter/oauth.json`. Any
flow that can refresh does: an explicit `refresh` flow, and an `oauth2` flow
whose token endpoint returned a `refresh_token` — a 401 invalidates the
cached token and retries once via the refresh grant.

### Streaming (SSE), pagination & per-request curl

```http
### Stream events as they arrive
# @stream
GET https://api.example.com/events

### Follow rel="next" Link headers (concatenates JSON-array pages)
# @paginate
# @max-pages 10
GET https://api.example.com/items?page=1
```

`# @stream` pipes `curl -N` output into a live float (`:TuiterStream`).
Other per-request directives: `# @timeout 5`, `# @no-redirect`, `# @no-log`,
`# @delay 500`, `# @cert path`, `# @key path`, `# @proxy url`, `# @insecure`.

### Import (Postman / OpenAPI / curl)

```vim
:TuiterImportPostman collection.json   " opens a new .http buffer
:TuiterImportOpenapi openapi.json
:TuiterImportCurl                     " paste a curl command (DevTools / docs / gh api -i)
```

Postman collections are flattened (folders included); OpenAPI specs become one
request per path+method with query params and example bodies. `:TuiterImportCurl`
parses DevTools-style commands (`-X -H -d/--data-raw -F -u -A -k -G …`) into a
new `.http` buffer — it prefills from the `"` register when it holds a curl
command.

### `.env` support

A `.env` file (searched upward from the request file) provides a base layer of
`{{vars}}`; the selected JSON environment wins on conflicts. Works with or
without an env JSON file. Env files are hot-reloaded: editing
`tuiter.env.json` / `http-client.env.json` takes effect on the next request
without switching environments.

### Watch & format

- `:TuiterWatch [seconds]` — re-run the request under the cursor every N
  seconds, notifying on status changes (toggle again to stop)
- `:TuiterFormat` — pretty-print the JSON body of the request under the cursor
- `:TuiterScaffold` — new `.http` buffer with tests/auth/formatting examples

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
| `:TuiterCopyAs [curl\|python\|js\|ts\|go\|rust\|php\|graphql]` | Copy the request under the cursor as a code snippet (no arg = picker) |
| `:TuiterStream` | Stream the request under the cursor (SSE, `# @stream`) |
| `:TuiterWatch [sec]` | Re-run request every N seconds; toggle to stop |
| `:TuiterJUnit [path]` | Export the last run-all results as JUnit XML |
| `:TuiterCI` | Run all + write JUnit + exit non-zero on failure (CI) |
| `:TuiterScaffold` | Open a scaffolded `.http` buffer |
| `:TuiterFormat` | Pretty-print the request body JSON under the cursor |
| `:TuiterImportPostman [file]` | Convert a Postman collection to a `.http` buffer |
| `:TuiterImportOpenapi [file]` | Convert an OpenAPI spec to a `.http` buffer |
| `:TuiterImportCurl` | Paste a curl command → new `.http` buffer |

## Health check

`:checkhealth tuiter` verifies Neovim >= 0.10, `curl` on PATH, and that the
data + cookie-jar directories under `stdpath("data")/tuiter` are writable
(plus an info note when `jq` is missing for the `J` filter).

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

`require("tuiter").statusline()` returns `dev · HTTP 200` for the current
environment and last response — drop it into lualine or a custom statusline:

```lua
-- lualine
{ "tuiter.statusline", cond = function() return require("tuiter").statusline() ~= "" end }
```

The response window statusline shows `METHOD url  200  45ms · 1.2KB · json · dev │ key hints`
(method color-coded, status badge with colored background) in a single
dense line.

## How it works

```
<leader>is on a .http file
      │
      ▼
parser.lua        parse buffer → request spec {method, url, headers, body, vars, scripts}
      │
      ▼
client.lua        substitute {{vars}} + {{$dynamic}} → run # @before → curl_args()
      │           → vim.system(curl, async) → run # @after
      ▼
client.lua        parse_response() splits headers/body + status/time/size
      │  (vim.schedule — curl callbacks fire in a fast-event context,
      │   deferred to the main loop before touching windows)
      ▼
ui.lua            show(): loading spinner → pretty-print JSON → treesitter json →
                  floats/splits + status bar + method-colored badges
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
require("tuiter").statusline()           -- "dev · HTTP 200" for lualine
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

Environments can inherit from a base environment — the `"$extends"` key
merges that environment's vars underneath the child's (child wins on
conflicts, cycles are ignored):

```json
{
  "base": { "host": "https://api.example.com", "version": "v1" },
  "dev":  { "$extends": "base", "token": "dev-token" },
  "prod": { "$extends": "base", "token": "prod-token" }
}
```

Now `dev` and `prod` share `host`/`version` and only differ on `token` —
add a shared variable once in `base` instead of three times.

## Configuration

```lua
{
  opts = {
    keymaps = { -- false disables that key; keymaps = false disables all
      run = "<leader>is", list = "<leader>il", run_all = "<leader>ia",
      cancel = "<leader>ic", help = "<leader>ik",
      history = "<leader>ih", env = "<leader>ie", response = "<leader>ir",
      vars = "<leader>iv", -- show resolved {{vars}} of the request under cursor
      browser = "gx", -- open request URL in browser (vim.ui.open)
    },
    curl = { timeout = 30, insecure = false, max_redirects = 8, cookie_jar = true, compressed = true },
    env_files = { "http-client.env.json", "tuiter.env.json" },
    default_env = "default",
    run_all = { concurrency = 1, delay = 150 }, -- parallel collection runner
    windows = {
      layout = "float", -- "float" (default) or "split" (3-pane editor layout)
      response_side = "right",
      width = 120, max_height = 40, sidebar_width = 62,
    },
  },
}
```

### Layout modes

**`layout = "float"`** (default): sidebar and response open as floating windows.
Quick for spot-checking — `is` sends, response pops up, `q` dismisses.

**`layout = "split"`**: sidebar opens as a real `topleft vsplit` with
`winfixwidth`; response opens as a `botright vsplit`. The 3-pane layout
([.http] [sidebar] [response]) stays visible while you edit. Use `<leader>ir` to toggle the response split, `q` inside it
to close. The sidebar width is controlled by `windows.sidebar_width` (default
62); the response width by `windows.width` (default 120).

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
plugin/tuiter.lua        commands + filetype detection
ftplugin/http.lua        buffer keymaps + commentstring + omnifunc + diagnostics
                         + {{var}} hover (K) and definition jump (gd)
ftplugin/graphql.lua     same for .graphql buffers
lua/tuiter/init.lua      public API, config, run-all runner, watch/JUnit/CI/import
lua/tuiter/parser.lua    .http parsing + validation + directives (pure Lua)
lua/tuiter/graphql.lua   .graphql parsing (pure Lua)
lua/tuiter/client.lua    env/var resolution, dynamic values, curl, assertions,
                         named chaining, dotenv, pagination, streaming, pre/post scripts
lua/tuiter/auth.lua      OAuth2/bearer token management (cached)
lua/tuiter/codegen.lua   curl/python/js/ts/go/rust/php/graphql snippet generation
lua/tuiter/import.lua    Postman + OpenAPI -> .http conversion (pure functions)
lua/tuiter/ui.lua        response windows + request sidebar + run summary + streaming
                         + loading spinner + method-colored badges + split mode
lua/tuiter/history.lua   persisted request history (secrets redacted)
lua/tuiter/pickers.lua   Telescope picker providers
lua/telescope/_extensions/tuiter.lua  Telescope extension registration
syntax/http.vim          .http syntax highlighting (methods, URLs, headers, JSON)
```

### Telescope extension

```lua
require("telescope").load_extension("tuiter")
-- :Telescope tuiter history | requests | env
```

## Notes

- Keymaps use the `<leader>i` group — free in LazyVim (shown as a "tuiter"
  which-key group) and never clashes with harpoon (`<leader>h`/`<leader>H`/
  `<leader>1-9`), the test group (`<leader>t*`), or the http-client plugins
  (`<leader>ht`). Change them via `opts.keymaps`.
- History lives in `stdpath("data")/tuiter/history.json`; favorites in
  `stdpath("data")/tuiter/favorites.json`; cookies per project in
  `stdpath("data")/tuiter/cookies/`.
