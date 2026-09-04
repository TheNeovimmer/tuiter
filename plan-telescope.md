# Tuiter Telescope UI Plan

Replace sidebar with Telescope pickers for a senior-level keyboard-driven experience.
Keep response in floating/split window (Telescope can't display long content well).

## Context
- Current: sidebar (float/split) + Telescope for history/env/requests
- Goal: Full Telescope UI — all browsing/selection via Telescope pickers
- Response remains in float/split ( Telescope preview too limited for API responses)

## P10: Core Telescope Pickers

### Request Picker (replaces sidebar)
- `:Telescope tuiter requests` — main entry point
- Preview shows: method, URL, headers, body (first 50 lines)
- Actions:
  - `<CR>` — send request
  - `<C-o>` — go to request in file
  - `<C-f>` — toggle favorite
  - `<C-d>` — delete from history
  - `<C-e>` — edit request inline
  - `<C-t>` — add/edit tags
  - `<C-r>` — rename request
  - `<C-s>` — copy as curl
  - `<C-c>` — copy as code snippet
- Sorting: favorites first, then by last used, then alphabetical
- Filter: by method, tag, URL pattern, favorites only

### Collection Picker
- `:Telescope tuiter collections` — browse all collections
- Preview shows: collection name, file count, env file status
- Actions:
  - `<CR>` — open collection (shows request picker for that collection)
  - `<C-n>` — new collection
  - `<C-a>` — add current file to collection
  - `<C-d>` — delete collection
  - `<C-r>` — rename collection
- Sorting: by name, by file count, by last modified

### Template Picker
- `:Telescope tuiter templates` — browse all templates
- Preview shows: template name, method, content preview
- Actions:
  - `<CR>` — insert template at cursor
  - `<C-e>` — edit template
  - `<C-d>` — delete template (only custom)
  - `<C-s>` — save current request as template
- Sorting: built-in first, then custom, alphabetical

### History Picker (enhanced)
- `:Telescope tuiter history` — browse request history
- Preview shows: request + response (status, headers, body excerpt)
- Actions:
  - `<CR>` — replay request
  - `<C-d>` — delete from history
  - `<C-e>` — edit and replay
  - `<C-y>` — copy as curl
  - `<C-j>` — copy response body
  - `<C-t>` — show full response in float
- Sorting: by time (newest first), by method, by status
- Filter: by method, status code, URL pattern, date range

### Environment Picker
- `:Telescope tuiter env` — switch environment
- Preview shows: env name, all variables with values (redacted for secrets)
- Actions:
  - `<CR>` — switch to environment
  - `<C-e>` — edit env file
  - `<C-n>` — new environment
  - `<C-d>` — delete environment
  - `<C-c>` — copy env file path
- Sorting: by name, last used first

### Command Picker
- `:Telescope tuiter commands` — quick access to all tuiter commands
- Preview shows: command description, keymap if any
- Actions:
  - `<CR>` — execute command
  - `<C-y>` — copy command to clipboard
- Groups: Request, Response, Import/Export, Collection, Template, Config

## P11: Advanced Picker Features

### Multi-Select Mode
- `<Tab>` to select multiple requests
- `<S-Tab>` to deselect
- `<C-a>` to select all
- Actions work on all selected:
  - `<CR>` — run all selected
  - `<C-s>` — copy all as curl
  - `<C-y>` — copy all as code snippets

### Request Preview Enhancements
- Syntax-highlighted preview (methods, headers, JSON)
- Show resolved variables with values
- Show tags as badges
- Show favorite status
- Show last response status/time
- Collapsible sections (headers, body)

### Response Preview
- `<C-t>` in request/history picker shows full response
- Response preview with syntax highlighting
- Tab switching in preview (body/headers/timeline)
- Copy from preview (body, headers, curl)

### Smart Sorting
- Frequency-based sorting (most used requests first)
- Recency-based sorting (last used first)
- Custom sort orders (save and recall)
- Sort by response time (fastest endpoints first)

### Filter Syntax
- `method:GET` — filter by method
- `tag:auth` — filter by tag
- `status:200` — filter by last status
- `url:/users` — filter by URL pattern
- `fav:true` — filter favorites only
- `recent:7d` — requests from last 7 days
- Combine: `method:GET tag:auth fav:true`

## P12: Telescope Configuration

### Preview Settings
```lua
{
  preview = {
    width = 80,
    height = 20,
    syntax_highlight = true,
    wrap = true,
  },
  layout = {
    prompt_position = "top",
    preview_width = 0.5,
  },
}
```

### Action Mappings
```lua
{
  mappings = {
    i = {
      ["<CR>"] = "select_default",
      ["<C-o>"] = "goto_file",
      ["<C-f>"] = "toggle_favorite",
      ["<C-d>"] = "delete",
      ["<C-e>"] = "edit",
      ["<C-t>"] = "preview_response",
      ["<C-s>"] = "copy_curl",
      ["<C-c>"] = "copy_code",
      ["<Tab>"] = "toggle_selection",
      ["<S-Tab>"] = "toggle_selection_prev",
      ["<C-a>"] = "select_all",
    },
  },
}
```

### Sorters
```lua
{
  sorter = {
    frequency = true,  -- most used first
    recency = true,    -- last used first
    fuzzy = true,      -- fuzzy matching
  },
}
```

## P13: Integration

### Sidebar → Telescope Migration
- `<leader>il` now opens Telescope request picker
- `<leader>ih` now opens Telescope history picker
- `<leader>ie` now opens Telescope env picker
- Keep `<leader>is` for quick send (no picker)

### Response Window
- Response still opens in float/split after send
- `<leader>ir` toggles response window
- Response can be opened from Telescope preview with `<C-t>`

### Quick Actions
- `<leader>iq` — command picker (all tuiter commands)
- `<leader>it` — template picker
- `<leader>ic` — collection picker

## Implementation Order

### Phase 1: Core Pickers
1. Enhanced request picker with preview and actions
2. Enhanced history picker with response preview
3. Enhanced env picker with variable preview

### Phase 2: Collection & Template
4. Collection picker
5. Template picker
6. Command picker

### Phase 3: Advanced Features
7. Multi-select mode
8. Filter syntax
9. Smart sorting
10. Response preview in picker

## Technical Notes

- All pickers use telescope.nvim as dependency
- Fallback to vim.ui.select when telescope not available
- Preview uses buffer highlights for syntax
- Actions are configurable via opts
- Frequency/recency tracked in stdpath("data")/tuiter/stats.json

## Success Metrics

- All interactions keyboard-driven (no mouse)
- <=2 keys for common actions
- Fuzzy finding for 100+ requests
- Preview shows enough context to identify requests
- Response time < 100ms for picker operations