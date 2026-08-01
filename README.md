# tuiter

Interactive API explorer for Neovim. Write requests in `.http` files, send
them with one key, read the response in a floating window — with history,
environments, and JSON pretty-printing. A lightweight Postman for your editor,
written in pure Lua.

## Features

- **`.http` request files** — REST Client format: methods, headers, bodies, named `###` sections
- **Async requests** — `curl` via `vim.system`, no plugin dependencies
- **Response window** — status summary, headers, body; JSON pretty-printed and treesitter-highlighted
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
  cmd = { "Tuiter", "TuiterRun", "TuiterHistory", "TuiterEnv" },
  ft = "http",
  opts = {},
}
```

## Usage

Open a `.http` file and place the cursor on a request:

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

| Key / command | Action |
|---|---|
| `<leader>ht` / `:TuiterRun` | Send request under cursor |
| `<leader>hh` / `:TuiterHistory` | Pick a past request and re-run it |
| `<leader>he` / `:TuiterEnv` | Select environment |
| `<leader>hc` / `:Tuiter` | Toggle response window |
| `q` / `t` / `r` (in response) | Close / toggle headers / resend |

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
switch with `:TuiterEnv`.

## Configuration

```lua
{
  opts = {
    keymaps = { run = "<leader>ht", history = "<leader>hh", env = "<leader>he", toggle = "<leader>hc" }, -- or false
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
lua/tuiter/ui.lua      response floating windows
lua/tuiter/history.lua persisted request history
```

## Notes

- If another plugin maps `<leader>ht` on `.http` buffers (e.g. kulala.nvim),
  set `keymaps = false` or change the keys — tuiter's mappings are
  buffer-local so global ones lose.
- History lives in `stdpath("data")/tuiter/history.json`.
