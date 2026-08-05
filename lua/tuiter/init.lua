--- tuiter: interactive API explorer for Neovim.
--- Public API + wiring: config, run/resend, run-all, sidebar, history, env,
--- response, request navigation, lualine statusline helper.
local parser = require("tuiter.parser")
local client = require("tuiter.client")
local ui = require("tuiter.ui")
local history = require("tuiter.history")
local codegen = require("tuiter.codegen")

local M = {}

local LANG_NAMES = { "curl", "python", "js", "ts", "go", "rust", "php", "graphql" }

local config = {
	keymaps = {
		run = "<leader>is", -- send request under cursor
		list = "<leader>il", -- request sidebar (Postman-style)
		run_all = "<leader>ia", -- run every request in the file
		cancel = "<leader>ic", -- cancel in-flight requests
		help = "<leader>ik", -- keymap help float
		history = "<leader>ih",
		env = "<leader>ie",
		response = "<leader>ir", -- toggle response window
	},
	curl = { timeout = 30, insecure = false, max_redirects = 8, cookie_jar = true, compressed = true },
	env_files = { "http-client.env.json", "tuiter.env.json" },
	default_env = "default",
	run_all = { concurrency = 1, delay = 150 },
	windows = { width = 120, max_height = 40, sidebar_width = 62 },
}

---@param opts? table
function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})
	-- LazyVim/which-key group label for the <leader>i prefix (no-op without which-key)
	pcall(function()
		local wk = require("which-key")
		if wk and wk.add then
			wk.add({ { "<leader>i", group = "tuiter" } })
		end
	end)
end

--- The active config (post-setup).
function M.opts()
	return config
end

--- Parse a buffer with the right parser for its filetype.
local function parse_buffer(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	if vim.bo[buf].filetype == "graphql" then
		return require("tuiter.graphql").parse(lines)
	end
	return parser.parse_lines(lines)
end

--- The request under the cursor of buffer opts.buf (or the current one).
---@return integer buf, table? spec
local function request_under_cursor(opts)
	opts = opts or {}
	local buf = opts.buf or 0
	if buf == 0 then
		buf = vim.api.nvim_get_current_buf()
	end
	local lnum = opts.lnum or vim.api.nvim_win_get_cursor(0)[1]
	return buf, parser.at(parse_buffer(buf), lnum)
end

local function copy_curl(spec)
	vim.fn.setreg('"', client.curl_command(spec, config.curl))
	vim.notify("Tuiter: curl command copied", vim.log.levels.INFO, { title = "Tuiter" })
end

--- Send a request spec directly (no buffer parsing). Async; shows the
--- response window and records history when done.
---@param spec table {method, url, headers?, body?, vars?, name?, cwd?}
function M.resend(spec)
	local cwd = spec.cwd or vim.fn.getcwd()
	if not spec.url then
		vim.notify("Tuiter: request has no URL (add a # @url directive)", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	client.ensure_env(cwd, config)
	spec.env = client.state.env
	vim.notify(string.format("Tuiter: %s %s", spec.method, spec.url), vim.log.levels.INFO, { title = "Tuiter" })
	client.send(spec, config.curl, cwd, function(resp)
		vim.schedule(function()
			client.record_response(resp, spec)
			ui.show(resp, spec, {
				buf = spec.buf or M.source_buf,
				windows = config.windows,
				resend = function()
					M.resend(spec)
				end,
				copy_curl = function()
					copy_curl(spec)
				end,
				copy_code = function()
					M.copy_code_for(spec)
				end,
			})
			if not (spec.no_log or (spec.opts and spec.opts.no_log)) then
				history.add(spec, resp)
			end
		end)
	end)
end

--- Send the request under the cursor (or at opts.lnum) of buffer opts.buf.
---@param opts? {buf?: integer, lnum?: integer}
function M.run(opts)
	opts = opts or {}
	local buf, spec = request_under_cursor(opts)
	if not spec then
		vim.notify("Tuiter: no request found under cursor", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	M.source_buf = buf
	spec.buf = buf
	spec.cwd = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p:h")
	M.resend(spec)
end

--- Run every request in the buffer; show a results summary.
--- Concurrency: opts.run_all.concurrency (default 1, i.e. sequential).
--- The final results are kept in M.last_run for :TuiterJUnit / :TuiterCI.
---@param opts? {buf?: integer}
function M.run_all(opts)
	opts = opts or {}
	local buf = opts.buf or 0
	if buf == 0 then
		buf = vim.api.nvim_get_current_buf()
	end
	local requests = parse_buffer(buf)
	if #requests == 0 then
		vim.notify("Tuiter: no requests in this buffer", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	M.source_buf = buf
	local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p:h")
	client.ensure_env(dir, config)
	local results = {}
	local concurrency = math.max(1, tonumber((config.run_all or {}).concurrency) or 1)
	local delay = tonumber((config.run_all or {}).delay) or 150
	local function finish()
		vim.schedule(function()
			M.last_run = results
			if opts.on_done then
				opts.on_done(results)
			end
			if not opts.no_summary then
				ui.show_run_summary(results, { buf = buf })
			end
		end)
	end
	local next_index, in_flight = 1, 0
	local function pump()
		if next_index > #requests and in_flight == 0 then
			finish()
			return
		end
		while in_flight < concurrency and next_index <= #requests do
			local i = next_index
			next_index = next_index + 1
			in_flight = in_flight + 1
			local spec = vim.deepcopy(requests[i])
			spec.cwd = dir
			spec.buf = buf
			spec.env = client.state.env
			if spec.opts and spec.opts.skip then
				-- # @skip: excluded from run-all / CI (e.g. destructive requests)
				results[i] = { spec = spec, skipped = true }
				in_flight = in_flight - 1
				vim.defer_fn(pump, delay)
			elseif not spec.url or not spec.method then
				-- heading-only request (e.g. a bare ### comment block): skip
				results[i] = {
					spec = spec,
					resp = { ok = false, status = 0, headers = "", body = "", error = "no method/URL" },
				}
				in_flight = in_flight - 1
				vim.defer_fn(pump, delay)
			else
				client.send(spec, config.curl, dir, function(resp)
					vim.schedule(function()
						client.record_response(resp, spec)
						ui.mark_response(spec, resp)
						results[i] = { spec = spec, resp = resp }
						in_flight = in_flight - 1
						vim.defer_fn(pump, delay)
					end)
				end)
			end
		end
	end
	vim.notify(string.format("Tuiter: running %d requests…", #requests), vim.log.levels.INFO, { title = "Tuiter" })
	pump()
end

--- Move to the next/previous request in the buffer.
---@param dir integer 1 = next, -1 = previous
function M.jump_request(dir)
	local buf = 0
	local requests = parse_buffer(buf)
	if #requests == 0 then
		return
	end
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local idx = 1
	for i, r in ipairs(requests) do
		if r.line <= lnum then
			idx = i
		end
	end
	local target = idx + dir
	if target < 1 or target > #requests then
		return
	end
	vim.api.nvim_win_set_cursor(0, { requests[target].line, 0 })
end

--- Open (or close) the request sidebar for the current .http buffer.
--- The sidebar stays open while running (Insomnia-style); response floats
--- open to its right.
function M.sidebar()
	if ui.sidebar_is_open() then
		ui.close_sidebar()
		return
	end
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].buftype ~= "" then
		-- inside a scratch/response buffer: reuse the last http buffer
		buf = (M.source_buf and vim.api.nvim_buf_is_valid(M.source_buf) and M.source_buf) or 0
	end
	local requests = parse_buffer(buf)
	if #requests == 0 then
		vim.notify("Tuiter: no requests in this buffer", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p:h")
	client.ensure_env(dir, config)
	local function open()
		ui.show_sidebar(requests, {
			title = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"),
			env = client.state.env,
			run = function(spec)
				spec.cwd = dir
				spec.buf = buf
				M.resend(spec)
			end,
			go_to = function(lnum)
				if vim.api.nvim_buf_is_valid(buf) then
					vim.api.nvim_set_current_buf(buf)
					vim.api.nvim_win_set_cursor(0, { lnum, 0 })
				end
			end,
			copy_curl = copy_curl,
			run_all = function()
				M.run_all({ buf = buf })
			end,
			switch_env = function()
				M.select_env({ cwd = dir }, open)
			end,
			windows = config.windows,
		})
	end
	open()
end

--- Pick a past request from history and re-run it.
function M.history()
	history.pick(function(spec)
		M.resend(spec)
	end)
end

--- Cancel all in-flight requests.
function M.cancel()
	client.cancel()
	vim.notify("Tuiter: canceled in-flight requests", vim.log.levels.INFO, { title = "Tuiter" })
end

---@param opts? {cwd?: string}
---@param on_select? fun(name: string) called after the environment is set
function M.select_env(opts, on_select)
	opts = opts or {}
	local cwd = opts.cwd or vim.fn.getcwd()
	local envs = client.envs(cwd, config)
	if #envs == 0 then
		vim.notify(
			"Tuiter: no env file found (looked for " .. table.concat(config.env_files, ", ") .. ")",
			vim.log.levels.WARN,
			{ title = "Tuiter" }
		)
		return
	end
	vim.ui.select(envs, { prompt = "Tuiter environment" }, function(name)
		if name then
			client.set_env(name, cwd, config)
			vim.notify(string.format("Tuiter: environment set to %q", name), vim.log.levels.INFO, { title = "Tuiter" })
			if on_select then
				on_select(name)
			end
		end
	end)
end

function M.toggle_response()
	ui.toggle()
end

--- Pick a language and copy the code snippet for `spec` (Insomnia-style).
function M.copy_code_for(spec)
	vim.ui.select(LANG_NAMES, { prompt = "Tuiter: copy as…" }, function(lang)
		if lang then
			vim.fn.setreg('"', codegen.generate(lang, spec, config.curl))
			vim.notify("Tuiter: " .. lang .. " snippet copied", vim.log.levels.INFO, { title = "Tuiter" })
		end
	end)
end

--- :TuiterCopyAs {curl|python|js|go} — copy a snippet for the request under
--- the cursor. Without an argument, opens a picker.
---@param lang? string
function M.copy_as(lang)
	local _, spec = request_under_cursor()
	if not spec then
		vim.notify("Tuiter: no request under cursor", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	if lang and vim.tbl_contains(LANG_NAMES, lang) then
		vim.fn.setreg('"', codegen.generate(lang, spec, config.curl))
		vim.notify("Tuiter: " .. lang .. " snippet copied", vim.log.levels.INFO, { title = "Tuiter" })
	else
		M.copy_code_for(spec)
	end
end

function M.close_response()
	ui.close()
end

--- Omnifunc entry: loads the env (if any) so completion sees {{vars}}.
function M.complete(findstart, base)
	client.ensure_env(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p:h"), config)
	return client.complete(findstart, base)
end

--- Statusline component for lualine/statuscol (e.g. "env: dev · HTTP 200").
function M.statusline()
	local parts = {}
	if client.state.env then
		parts[#parts + 1] = "env: " .. client.state.env
	end
	local r = client.state.response
	if r and r.status and r.status > 0 then
		parts[#parts + 1] = "HTTP " .. r.status
	end
	return table.concat(parts, " · ")
end

--- Register buffer-local keymaps (called from ftplugin/http.lua).
---@param buf integer
function M.setup_keymaps(buf)
	local km = config.keymaps
	if not km then
		return
	end
	local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p:h")
	local function map(lhs, cb, desc)
		vim.keymap.set("n", lhs, cb, { buffer = buf, desc = "Tuiter: " .. desc })
	end
	if km.run then
		map(km.run, function()
			M.run({ buf = buf })
		end, "Send request under cursor")
	end
	if km.list then
		map(km.list, M.sidebar, "Request sidebar")
	end
	if km.run_all then
		map(km.run_all, function()
			M.run_all({ buf = buf })
		end, "Run all requests")
	end
	if km.cancel then
		map(km.cancel, M.cancel, "Cancel in-flight requests")
	end
	if km.help then
		map(km.help, function()
			ui.toggle_help()
		end, "Show keymap help")
	end
	if km.history then
		map(km.history, M.history, "Request history")
	end
	if km.env then
		map(km.env, function()
			M.select_env({ cwd = dir })
		end, "Select environment")
	end
	if km.response then
		map(km.response, M.toggle_response, "Toggle response")
	end
	map("]r", function()
		M.jump_request(1)
	end, "Next request")
	map("[r", function()
		M.jump_request(-1)
	end, "Previous request")
end

-- ---------------------------------------------------------------------------
-- Stream / watch / JUnit / CI / scaffold / format / import
-- ---------------------------------------------------------------------------

--- Stream the request under the cursor (SSE, `# @stream`): curl -N chunks
--- appended live into a scratch float.
---@param opts? {buf?: integer, lnum?: integer}
function M.stream(opts)
	opts = opts or {}
	local buf, spec = request_under_cursor(opts)
	if not spec then
		vim.notify("Tuiter: no request under cursor", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p:h")
	client.ensure_env(dir, config)
	spec.cwd, spec.env = dir, client.state.env
	ui.open_stream(spec)
	client.send_stream(spec, config.curl, dir, function(data)
		ui.stream_chunk(data)
	end, function(code)
		vim.schedule(function()
			ui.stream_end(code)
		end)
	end)
end

--- Healthcheck: re-run the request under the cursor every N seconds, notifying
--- on status changes. Calling again stops. `:TuiterWatch [seconds]`.
---@param opts? {buf?: integer, seconds?: integer}
function M.watch(opts)
	opts = opts or {}
	if M._watch then
		M._watch:stop()
		M._watch = nil
		vim.notify("Tuiter: watch stopped", vim.log.levels.INFO, { title = "Tuiter" })
		return
	end
	local buf, spec = request_under_cursor(opts)
	if not spec then
		return
	end
	local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p:h")
	client.ensure_env(dir, config)
	spec.cwd, spec.env = dir, client.state.env
	local sec = math.max(1, tonumber(opts.seconds) or 5)
	local last = nil
	local function tick()
		client.send(spec, config.curl, dir, function(resp)
			vim.schedule(function()
				client.record_response(resp, spec)
				ui.mark(spec.url, resp.status)
				if last == nil then
					vim.notify(
						string.format("Tuiter watch: HTTP %d (%dms)", resp.status, (resp.time or 0) * 1000),
						vim.log.levels.INFO,
						{ title = "Tuiter" }
					)
				elseif resp.status ~= last then
					vim.notify(
						string.format("Tuiter watch: %s → HTTP %d (was %d)", spec.url, resp.status, last),
						resp.status < 400 and vim.log.levels.INFO or vim.log.levels.WARN,
						{ title = "Tuiter" }
					)
				end
				last = resp.status
			end)
		end)
	end
	tick()
	M._watch = vim.uv.new_timer()
	M._watch:start(
		sec * 1000,
		sec * 1000,
		vim.schedule_wrap(function()
			if vim.api.nvim_buf_is_valid(buf) then
				tick()
			end
		end)
	)
	vim.notify(
		string.format("Tuiter: watching %s every %ds (toggle with :TuiterWatch)", spec.url, sec),
		vim.log.levels.INFO,
		{ title = "Tuiter" }
	)
end

local function xml_esc(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

--- Export the last run-all results as JUnit XML. `:TuiterJUnit [path]`.
function M.junit(path)
	local results = M.last_run
	if not results then
		vim.notify("Tuiter: no run results yet (run :TuiterRunAll first)", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	path = path or "tuiter-junit.xml"
	local cases, failures = {}, 0
	local time_total = 0
	for _, e in ipairs(results) do
		if e.skipped then
			local name = e.spec.name ~= "" and e.spec.name or (e.spec.method .. " " .. e.spec.url)
			cases[#cases + 1] =
				string.format('    <testcase classname="tuiter" name="%s" time="0.000"><skipped/></testcase>', xml_esc(name))
		else
			local resp = e.resp
			time_total = time_total + (resp.time or 0)
			local failed = not (resp.ok and resp.status < 400 and (resp.failures or 0) == 0)
			if failed then
				failures = failures + 1
			end
			local name = e.spec.name ~= "" and e.spec.name or (e.spec.method .. " " .. e.spec.url)
			local c = string.format('    <testcase classname="tuiter" name="%s" time="%.3f"', xml_esc(name), resp.time or 0)
			if failed then
				local msg = string.format(
					"HTTP %d%s",
					resp.status,
					(resp.failures or 0) > 0 and string.format(" / %d assertion failure(s)", resp.failures) or ""
				)
				c = c .. '>\n      <failure message="' .. xml_esc(msg) .. '"/>\n    </testcase>'
			else
				c = c .. "/>"
			end
			cases[#cases + 1] = c
		end
	end
	local skipped = 0
	for _, e in ipairs(results) do
		if e.skipped then
			skipped = skipped + 1
		end
	end
	local xml = table.concat({
		'<?xml version="1.0" encoding="UTF-8"?>',
		string.format(
			'<testsuites tests="%d" failures="%d" skipped="%d" time="%.3f">',
			#results,
			failures,
			skipped,
			time_total
		),
		string.format(
			'  <testsuite name="tuiter" tests="%d" failures="%d" skipped="%d" time="%.3f">',
			#results,
			failures,
			skipped,
			time_total
		),
		table.concat(cases, "\n"),
		"  </testsuite>",
		"</testsuites>",
	}, "\n")
	vim.fn.writefile(vim.split(xml, "\n", { plain = true }), path)
	vim.notify(
		string.format("Tuiter: wrote %s (%d/%d passed)", path, #results - failures, #results),
		vim.log.levels.INFO,
		{ title = "Tuiter" }
	)
end

--- Run all requests headlessly and exit non-zero on failure (CI). Writes
--- JUnit XML (default tuiter-junit.xml). `nvim --headless +TuiterCI file.http`.
---@param opts? {buf?: integer, path?: string}
function M.ci(opts)
	opts = opts or {}
	M.run_all({
		buf = opts.buf or 0,
		no_summary = true,
		on_done = function(results)
			local failed = false
			for _, e in ipairs(results) do
				if not e.skipped then
					local resp = e.resp
					if not (resp.ok and resp.status < 400 and (resp.failures or 0) == 0) then
						failed = true
					end
				end
			end
			M.junit(opts.path or "tuiter-junit.xml")
			vim.defer_fn(function()
				vim.cmd(failed and "cquit 1" or "cquit")
			end, 100)
		end,
	})
end

local SCAFFOLD = table.concat({
	"### Example GET",
	"# @name example",
	"GET http://localhost:3000/resource",
	"Accept: application/json",
	"",
	"### Example POST (with a test)",
	"# @name create",
	"# @test status == 201",
	"# @test body.id exists",
	"POST http://localhost:3000/resource",
	"Content-Type: application/json",
	"",
	'{"name": "example"}',
	"",
}, "\n")

--- Open a scaffolded .http buffer with common patterns. `:TuiterScaffold`.
function M.scaffold()
	local buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_buf_set_name(buf, "requests.http")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(SCAFFOLD, "\n", { plain = true }))
	vim.bo[buf].filetype = "http"
	vim.api.nvim_set_current_buf(buf)
	vim.notify("Tuiter: scaffolded requests.http", vim.log.levels.INFO, { title = "Tuiter" })
end

--- Pretty-print the request body of the request under the cursor. `:TuiterFormat`.
function M.format()
	local buf, spec = request_under_cursor()
	if not spec then
		return
	end
	local pretty = spec.body and client.pretty_json(spec.body)
	if not pretty then
		vim.notify("Tuiter: body is not valid JSON", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	if not spec.body_line then
		vim.notify("Tuiter: cannot locate request body", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	local e = vim.api.nvim_buf_line_count(buf)
	for _, r in ipairs(parse_buffer(buf)) do
		if r.line > spec.line then
			e = r.line - 1
			break
		end
	end
	vim.api.nvim_buf_set_lines(buf, spec.body_line - 1, e, false, vim.split(pretty, "\n"))
	vim.notify("Tuiter: body formatted", vim.log.levels.INFO, { title = "Tuiter" })
end

--- Convert a Postman collection or OpenAPI spec into a new .http buffer.
--- `:TuiterImportPostman <file>` / `:TuiterImportOpenapi <file>`.
function M.import(kind, file)
	file = file or vim.fn.expand("<cfile>")
	if file == "" then
		vim.ui.input({ prompt = "Path to spec file:" }, function(p)
			if p then
				M.import(kind, p)
			end
		end)
		return
	end
	if vim.fn.filereadable(file) == 0 then
		vim.notify("Tuiter: file not readable: " .. file, vim.log.levels.ERROR, { title = "Tuiter" })
		return
	end
	local f = io.open(file, "r")
	local content = f:read("*a")
	f:close()
	local imp = require("tuiter.import")
	local text, err = imp[kind](content)
	if err then
		vim.notify("Tuiter: " .. err, vim.log.levels.ERROR, { title = "Tuiter" })
		return
	end
	local buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_buf_set_name(buf, kind == "postman" and "postman.http" or "openapi.http")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
	vim.bo[buf].filetype = "http"
	vim.api.nvim_set_current_buf(buf)
	vim.notify("Tuiter: imported " .. file, vim.log.levels.INFO, { title = "Tuiter" })
end

--- The active env file path (for `gd` definition-jumping).
function M.env_file()
	return client.state.env_file
end

return M
