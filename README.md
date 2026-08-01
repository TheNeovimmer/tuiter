# tuiter

Interactive API explorer for Neovim. Write requests in `.http` files, send
them with one key, read the response in a floating window — with a
Postman-style request sidebar, history, environments, and JSON
pretty-printing. A lightweight Insomnia/Postman for your editor, written in
pure Lua.

## Features

- **`.http` request files** — REST Client format: methods, headers, bodies, named `###` sections
- **Request sidebar** — Postman-style list of every request in the file, run or jump from it
- **Async requests** — `curl` via `vim.system`, no plugin dependencies
- **Response window** — status summary, headers, body; JSON pretty/raw toggle
- **Copy as curl** — Insomnia-style shell-safe curl command, one key
- **History** — every request is stored and replayable from a picker
- **Environments** — `http-client.env.json` / `tuiter.env.json` with `{{var}}` substitution
- **Request-scoped vars** — `@token = abc` lines
- **LazyVim-ready** — lazy-loaded, `which-key` descriptions, works with any picker via `vim.ui.select`

## Requirements

- Neovim >= 0.10 (uses `vim.system`, window titles, `vim.json`)
- `curl` on PATH

## Installation (LazyVim / lazy.nvim)

```lua
{
  dir = "~/path/to/tuiter", -- or "user/tuiter" once published
  cmd = { "Tuiter", "TuiterRun", "TuiterHistory", "TuiterEnv", "TuiterResponse" },
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

### Keymaps (`.http` files, `<leader>i` group)

| Key | Action |
|---|---|
| `<leader>is` | Send request under cursor |
| `<leader>il` | Request sidebar (like Postman's collection list) |
| `<leader>ih` | Request history (pick & re-run) |
| `<leader>ie` | Select environment |
| `<leader>ir` | Toggle response window |

### Request sidebar (`<leader>il` / `:Tuiter`)

Lists every request in the file — method (color-coded), name, URL, and the
last response status. `<CR>` runs, `g` jumps to the source line, `q` closes.

### Response window

Headers on top, body below. JSON bodies are pretty-printed and
treesitter-highlighted; the window title shows status · time · size and the
active environment.

| Key | Action |
|---|---|
| `q` | Close response |
| `t` | Toggle headers window |
| `p` | Toggle pretty / raw JSON body |
| `y` | Copy body to clipboard register |
| `c` | Copy as curl command (Insomnia-style) |
| `r` | Resend the request |

### Insomnia / Postman mapping

| Insomnia | tuiter |
|---|---|
| Send (`Ctrl+Enter`) | `<leader>is` or `<CR>` in sidebar |
| Collection sidebar | `<leader>il` |
| Environment selector | `<leader>ie` |
| Recent requests | `<leader>ih` |
| Copy as curl | `c` in response window |

### Commands

| Command | Action |
|---|---|
| `:Tuiter` | Toggle request sidebar |
| `:TuiterRun [lnum]` | Send request under cursor |
| `:TuiterHistory` | Pick a past request and re-run it |
| `:TuiterEnv` | Select environment |
| `:TuiterResponse` | Toggle response window |

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
      run = "<leader>is", list = "<leader>il", history = "<leader>ih",
      env = "<leader>ie", response = "<leader>ir",
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
ftplugin/http.lua      buffer keymaps + commentstring
lua/tuiter/init.lua    public API, config
lua/tuiter/parser.lua  .http parsing (pure Lua)
lua/tuiter/client.lua  env/var resolution, curl, response parsing, JSON pretty
lua/tuiter/ui.lua      response windows + request sidebar
lua/tuiter/history.lua persisted request history
```

## Notes

- Keymaps use the `<leader>i` group — free in LazyVim and never clashes with
  harpoon (`<leader>h`/`<leader>H`/`<leader>1-9`), the test group
  (`<leader>t*`), or the http-client plugins (`<leader>ht`). Change them via
  `opts.keymaps`.
- History lives in `stdpath("data")/tuiter/history.json`.
