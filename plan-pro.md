# Tuiter Pro Plan

Professional-grade features for daily Neovim API developers.
Zero deps maintained: pure Lua + curl, Neovim >=0.10, LazyVim-ready.

## Context
- Daily workflow: 20-50 requests/day across multiple projects
- Pain points: repetitive request writing, debugging failures, sharing with team, tracking changes
- Goal: make tuiter the only API tool you need, fully keyboard-driven

## P4: Request Organization & Templates

### Collections
- Store requests in `*.http.collections/` directory (git-friendly)
- `:TuiterCollection new <name>` — scaffold a collection folder
- `:TuiterCollection add` — add current file to collection
- `:TuiterCollection list` — Telescope picker with collection stats
- Collection-specific env files (`collection.env.json` overrides root)

### Templates & Snippets
- `:TuiterSnippet list` — picker with saved request templates
- `:TuiterSnippet save` — save current request as template
- `:TuiterSnippet insert <name>` — insert template at cursor
- Built-in templates: CRUD, auth flow, pagination, GraphQL mutation
- Templates support `{{cursor}}` placeholder for jump position

### Request Tags
- `# @tag auth,breaking,slow` — tag requests for filtering
- `:TuiterTag <tag>` — filter sidebar to show only tagged requests
- Tags appear in sidebar: `[auth] POST /login`
- `# @skip` requests shown greyed out, `# @breaking` shown red

## P5: API Development Workflow

### Schema Validation
- `# @schema response.json` — validate response against JSON Schema file
- Response tab shows ✓/✗ with details on mismatch
- `:TuiterValidate` — validate last response against schema
- Auto-detect `openapi.json` in project root for request validation

### Mock Server
- `:TuiterMock start` — start local mock server from `tuiter.mocks.json`
- Mock responses defined per URL pattern + method
- `# @mock 200 {"users": [...]}` — inline mock response for request
- Mock state: track call count, last body, for assertions
- `:TuiterMock stop` — shutdown mock server

### Request Replay & Compare
- `D` in response window now shows diff picker (last vs current)
- `:TuiterCompare <file1> <file2>` — diff two response files
- `:TuiterReplay` — replay last N requests with timing comparison
- Response history with timestamps, filterable by URL/method/status

### Auto-Retry
- `# @retry 3 1000` — retry failed request 3 times, 1s delay
- Exponential backoff option: `# @retry 3 1000 exponential`
- Retry on specific status: `# @retry 5 500,503`
- Show retry count in response: `[retry 2/3] 200 OK`

## P6: Debugging & Analysis

### Request Inspector
- `<leader>ii` — open request inspector float
- Shows: full curl command, resolved vars, headers, body, timing breakdown
- Editable: modify and resend directly from inspector
- Copy sections: `y` (curl), `Y` (headers), `B` (body)

### Response Analysis
- `:TuiterAnalyze` — response analysis tab
- JSON path autocomplete in `# @test` assertions
- Response size breakdown: headers, body, overhead
- Content-type detection and appropriate formatting
- `:TuiterTiming` — timing history for current URL (avg, min, max, p95)

### Request History Search
- `:TuiterHistory search <query>` — fuzzy search across all history
- Filter by: method, URL, status, date range, tags
- Export history to collection: `:TuiterHistory export <collection>`
- History entries show response preview in Telescope

### Diff Mode
- `<leader>id` — diff current response vs previous for same URL
- Side-by-side or unified diff view
- Highlight changed fields in JSON
- `:TuiterDiff file1.json file2.json` — compare any two files

## P7: Productivity & Speed

### Quick Actions
- `<leader>iq` — quick action picker:
  - Send request
  - Copy as curl
  - Copy as code
  - Save response
  - Add to collection
  - Tag request
  - Run tests
- Actions context-aware: shows relevant options for current buffer/window

### Request Bookmarks
- `m` in sidebar — bookmark request (persisted across sessions)
- `:TuiterBookmarks` — picker showing all bookmarks
- Bookmarks section at top of sidebar (like favorites but global)
- `M` — manage bookmarks (rename, remove, group)

### Environment Switcher
- `<leader>ie` now shows env with preview (last response status)
- Quick switch: `<leader>ie` + number (1-9 for first 9 envs)
- Env groups: `dev.*`, `staging.*`, `prod.*` — switch all at once
- `.env` hot-reload with notification on change

### Smart Completion
- `<C-x><C-o>` now includes:
  - Request vars from current file
  - Env vars from active environment
  - Previous response fields (`{{$body.user.name}}`)
  - Common headers (`Authorization`, `Content-Type`, `Accept`)
  - Status codes for `# @test status ==`
- Completion shows source and type

### Request Navigation
- `<leader>in` — next request with preview
- `<leader>ip` — previous request with preview
- `]r`/`[r` now show mini preview of request
- `:TuiterGrep <pattern>` — find requests matching pattern

## P8: Collaboration & Sharing

### Collection Export
- `:TuiterCollection export <format>` — export collection as:
  - Postman collection (JSON)
  - OpenAPI spec (YAML/JSON)
  - curl scripts
  - Markdown documentation
- `:TuiterCollection import <file>` — import Postman/OpenAPI

### Request Notes
- `# @note Add user to database` — comment on request
- Notes shown in sidebar tooltip (hover or `?`)
- `:TuiterNotes` — picker showing all notes in file
- Notes included in collection export

### Git Integration
- `.tuiter-ignore` — files/patterns to exclude from history
- `:TuiterGit diff` — show changed requests since last commit
- `:TuiterGit log` — show request history with git blame
- Auto-commit collections on `:TuiterCollection export`

### Team Sharing
- `:TuiterShare` — generate shareable link (via local server or paste)
- Share collection as tarball with env examples
- `:TuiterFork <collection>` — clone collection with new env

## P9: Advanced Features

### WebSocket Support
- `# @ws` — WebSocket connection directive
- `:TuiterWs connect <url>` — open WebSocket connection
- Real-time message display in float
- Send messages interactively

### gRPC Support
- `.proto` file detection and parsing
- `# @grpc service.method` — gRPC request
- `:TuiterGrpc <proto> <method>` — invoke gRPC method
- Protobuf schema validation

### Data Generators
- `# @generate name:person.name` — generate fake data
- Integrates with lua-faker or similar (optional dep)
- Built-in generators: UUID, email, name, address, phone, date
- `# @generate body.user.email` — generate and insert into body

### Request Scheduling
- `# @schedule 0 */5 * * *` — cron expression for periodic runs
- `:TuiterSchedule list` — show scheduled requests
- `:TuiterSchedule start/stop` — toggle scheduler
- Log scheduled runs to file

### Performance Monitoring
- `:TuiterPerf` — performance dashboard
- Request timing history with charts (using ASCII art)
- Slow request detection (configurable threshold)
- API endpoint response time tracking

## Implementation Priority

### Phase 1 (Core Pro)
1. Collections & Templates (P4)
2. Request Inspector (P6)
3. Quick Actions (P7)

### Phase 2 (API Dev)
4. Schema Validation (P5)
5. Request Replay & Compare (P5)
6. Smart Completion (P7)

### Phase 3 (Collaboration)
7. Collection Export (P8)
8. Git Integration (P8)
9. Request Notes (P8)

### Phase 4 (Advanced)
10. Mock Server (P5)
11. Auto-Retry (P5)
12. WebSocket/gRPC (P9)

### Phase 5 (Power User)
13. Data Generators (P9)
14. Request Scheduling (P9)
15. Performance Monitoring (P9)

## Technical Notes

- All features maintain zero external deps
- New features use existing highlight groups where possible
- Collections use simple directory structure (git-friendly)
- Mock server uses built-in Lua HTTP (no deps)
- Schema validation uses `vim.json.decode` + simple validator
- gRPC/WebSocket need `curl` with appropriate flags (documented)

## Success Metrics

- Daily usage: 30+ requests/day without leaving Neovim
- Keyboard-only: all actions reachable in <=3 keys
- Shareability: team can use collections without tuiter docs
- Debugging: find issues in <30 seconds (inspector + diff)
- Speed: send request in <1 second from file open