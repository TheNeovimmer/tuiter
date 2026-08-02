--- tuiter: interactive API explorer for Neovim.
--- Public API + wiring: config, run/resend, run-all, sidebar, history, env,
--- response, request navigation, lualine statusline helper.
local parser = require("tuiter.parser")
local client = require("tuiter.client")
local ui = require("tuiter.ui")
local history = require("tuiter.history")
local codegen = require("tuiter.codegen")

local M = {}

local LANG_NAMES = { "curl", "python", "js", "go" }

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
			client.record_response(resp)
			ui.show(resp, spec, {
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

--- Run every request in the buffer sequentially; show a results summary.
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
	local function send_next(i)
		if i > #requests then
			vim.schedule(function()
				ui.show_run_summary(results, { buf = buf })
			end)
			return
		end
		local spec = requests[i]
		spec.cwd = dir
		spec.env = client.state.env
		client.send(spec, config.curl, dir, function(resp)
			vim.schedule(function()
				client.record_response(resp)
				ui.mark(spec.url, resp.status)
				results[i] = { spec = spec, resp = resp }
				vim.defer_fn(function()
					send_next(i + 1)
				end, 150) -- pace requests
			end)
		end)
	end
	vim.notify(string.format("Tuiter: running %d requests…", #requests), vim.log.levels.INFO, { title = "Tuiter" })
	send_next(1)
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

return M
