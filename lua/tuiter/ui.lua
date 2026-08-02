--- Response UI: floating windows for responses + a Postman-style request
--- sidebar. Favorites, zoom, copy-as-curl, run-all summary, keymap help.
local client = require("tuiter.client")

local M = {
	state = {
		head_win = nil,
		body_win = nil,
		help_win = nil,
		summary_win = nil,
		last = nil, -- { resp, spec, opts } of the last shown response
		pretty = true, -- pretty vs raw JSON body
		display = nil, -- { raw, pretty, json } of the shown body
		results = {}, -- url -> http status, shown as marks in the sidebar
		zoomed = false, -- body window maximized (headers hidden)
		favs = {}, -- url -> true (persisted)
		sidebar_win = nil,
		sidebar_buf = nil,
		sidebar_requests = {}, -- specs backing the current sidebar
		sidebar_opts = nil,
	},
}

local FAVS_FILE = vim.fn.stdpath("data") .. "/tuiter/favorites.json"

vim.api.nvim_set_hl(0, "TuiterOk", { link = "DiagnosticOk" })
vim.api.nvim_set_hl(0, "TuiterError", { link = "DiagnosticError" })
vim.api.nvim_set_hl(0, "TuiterGet", { link = "DiagnosticOk" })
vim.api.nvim_set_hl(0, "TuiterPost", { link = "DiagnosticInfo" })
vim.api.nvim_set_hl(0, "TuiterPut", { link = "DiagnosticWarn" })
vim.api.nvim_set_hl(0, "TuiterPatch", { link = "DiagnosticWarn" })
vim.api.nvim_set_hl(0, "TuiterDelete", { link = "DiagnosticError" })
vim.api.nvim_set_hl(0, "TuiterStar", { default = true, fg = "#f0c674" })
vim.api.nvim_set_hl(0, "TuiterStatusOk", { default = true, fg = "#0d1117", bg = "#3fb950" })
vim.api.nvim_set_hl(0, "TuiterStatusErr", { default = true, fg = "#0d1117", bg = "#f85149" })
vim.api.nvim_set_hl(0, "TuiterStatusHint", { default = true, fg = "#9da5b4", bg = "#24292f" })

local METHOD_HL = {
	GET = "TuiterGet",
	POST = "TuiterPost",
	PUT = "TuiterPut",
	PATCH = "TuiterPatch",
	DELETE = "TuiterDelete",
}

local HELP_SECTIONS = {
	{ "sidebar", "q close  <CR> run  g go-to-file  * favorite  a run all  c copy curl  ? help" },
	{ "response", "q close  t headers  p pretty/raw  y copy body  c copy curl  f save body  z zoom  r resend  ? help" },
	{
		"buffer",
		"<leader>is send  <leader>il sidebar  <leader>ia run all  ]r/[r next/prev  <leader>ih history  <leader>ie env  <leader>ir response",
	},
}

local function is_valid(w)
	return w and vim.api.nvim_win_is_valid(w)
end

local function trunc(s, n)
	s = s or ""
	return #s <= n and s or s:sub(1, n - 1) .. "…"
end

local function fmt_size(n)
	n = n or 0
	if n < 1024 then
		return string.format("%dB", n)
	end
	if n < 1024 * 1024 then
		return string.format("%.1fKB", n / 1024)
	end
	return string.format("%.1fMB", n / 1024 / 1024)
end

local function is_json(resp)
	if resp.headers:lower():match("content%-type:.-json") then
		return true
	end
	return resp.body:match("^%s*[%[{%]") ~= nil
end

local function mk_buf()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	return buf
end

local function buf_map(buf, lhs, rhs, desc)
	vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, desc = "Tuiter: " .. desc })
end

-- ---------------------------------------------------------------------------
-- Favorites
-- ---------------------------------------------------------------------------

local function load_favs()
	if vim.fn.filereadable(FAVS_FILE) == 0 then
		return
	end
	local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(FAVS_FILE), "\n"))
	if ok and type(data) == "table" then
		for _, url in ipairs(data) do
			M.state.favs[url] = true
		end
	end
end

load_favs()

local function save_favs()
	local urls = vim.tbl_keys(M.state.favs)
	table.sort(urls)
	vim.fn.mkdir(vim.fn.stdpath("data") .. "/tuiter", "p")
	pcall(vim.fn.writefile, { vim.json.encode(urls) }, FAVS_FILE)
end

function M.toggle_fav(url)
	if M.state.favs[url] then
		M.state.favs[url] = nil
	else
		M.state.favs[url] = true
	end
	save_favs()
	if is_valid(M.state.sidebar_win) then
		M.show_sidebar(M.state.sidebar_requests, M.state.sidebar_opts)
	end
end

-- ---------------------------------------------------------------------------
-- Response windows
-- ---------------------------------------------------------------------------

function M.close()
	for _, w in ipairs({ M.state.head_win, M.state.body_win }) do
		if is_valid(w) then
			pcall(vim.api.nvim_win_close, w, true)
		end
	end
	M.state.head_win, M.state.body_win = nil, nil
end

local function float_col()
	local col = 2
	if is_valid(M.state.sidebar_win) then
		local cfg = vim.api.nvim_win_get_config(M.state.sidebar_win)
		col = (cfg.col or 2) + (cfg.width or 60) + 2
	end
	return col
end

local function open_floats(head_buf, head_lines, body_buf, head_title, body_title)
	local cols, rows = vim.o.columns, vim.o.lines
	local col = float_col()
	local width = math.max(50, math.min(120, cols - col - 2))
	local zoomed = M.state.zoomed
	local head_win = nil
	local body_h
	if zoomed then
		body_h = math.min(rows - 6, 60)
	else
		local head_h = math.min(#head_lines + 2, 12)
		body_h = math.max(5, math.min(40, rows - head_h - 12))
		head_win = vim.api.nvim_open_win(head_buf, false, {
			relative = "editor",
			width = width,
			height = head_h,
			row = 2,
			col = col,
			border = "rounded",
			style = "minimal",
			title = " " .. head_title .. " ",
			title_pos = "center",
		})
	end
	local body_win = vim.api.nvim_open_win(body_buf, true, {
		relative = "editor",
		width = width,
		height = body_h,
		row = zoomed and 2 or 3 + math.min(#head_lines + 2, 12),
		col = col,
		border = "rounded",
		style = "minimal",
		title = " " .. body_title .. " ",
		title_pos = "center",
	})
	return head_win, body_win
end

local function set_statusline(win, resp, spec)
	local reason = resp.headers:match("^HTTP/%S+ %d+ ([^\r\n]*)") or ""
	local ok = resp.ok and resp.status < 400
	local hl = ok and "TuiterStatusOk" or "TuiterStatusErr"
	local env = spec.env and ("   env: " .. spec.env) or ""
	vim.wo[win].statusline = string.format(
		"%%#%s# tuiter  %s %s  ·  HTTP %d %s  ·  %dms  ·  %s%s %%*",
		hl,
		spec.method,
		spec.url,
		resp.status,
		reason ~= "" and reason or "",
		(resp.time or 0) * 1000,
		fmt_size(resp.size),
		env
	)
end

--- Show a response. opts: { resend = fn, copy_curl = fn }
function M.show(resp, spec, opts)
	opts = opts or {}
	M.state.last = { resp = resp, spec = spec, opts = opts }
	M.mark(spec.url, resp.status)
	M.close()

	-- status summary for the headers window title
	local reason = resp.headers:match("^HTTP/%S+ %d+ ([^\r\n]*)") or ""
	local status_line = string.format(
		"HTTP %d%s · %.0fms · %s",
		resp.status,
		reason ~= "" and (" " .. reason) or "",
		(resp.time or 0) * 1000,
		fmt_size(resp.size)
	)
	if not resp.ok and resp.error and resp.error ~= "" then
		status_line = status_line .. " · " .. resp.error:gsub("%s+", " "):sub(1, 60)
	end

	local head_buf = mk_buf()
	local hlines = resp.headers ~= "" and vim.split(resp.headers, "\n") or { "(no headers)" }
	vim.api.nvim_buf_set_lines(head_buf, 0, -1, false, hlines)
	vim.bo[head_buf].modifiable = false

	local body_buf = mk_buf()
	local json = is_json(resp)
	local pretty = json and client.pretty_json(resp.body) or nil
	M.state.pretty = json and pretty ~= nil
	M.state.display = { raw = resp.body, pretty = pretty, json = json }
	local body = M.state.pretty and (pretty or resp.body) or resp.body
	if body == "" then
		body = "(empty body)"
	end
	vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, vim.split(body, "\n"))
	if json then
		vim.bo[body_buf].filetype = "json"
		pcall(vim.treesitter.start, body_buf, "json")
	end
	vim.bo[body_buf].modifiable = false

	local env = spec.env and ("(env: " .. spec.env .. ")") or ""
	local head_win, body_win =
		open_floats(head_buf, hlines, body_buf, "response headers", string.format("%s %s %s", spec.method, spec.url, env))

	buf_map(head_buf, "q", M.close, "Close response")
	buf_map(head_buf, "t", M.toggle_headers, "Toggle headers")
	buf_map(body_buf, "q", M.close, "Close response")
	buf_map(body_buf, "t", M.toggle_headers, "Toggle headers")
	buf_map(body_buf, "p", M.toggle_pretty, "Toggle pretty/raw body")
	buf_map(body_buf, "y", M.yank_body, "Copy body")
	buf_map(body_buf, "f", M.save_body, "Save body to file")
	buf_map(body_buf, "z", M.toggle_zoom, "Zoom response")
	buf_map(body_buf, "?", M.toggle_help, "Show keymap help")
	buf_map(body_buf, "c", function()
		if opts.copy_curl then
			opts.copy_curl()
		end
	end, "Copy as curl")
	buf_map(body_buf, "r", function()
		if opts.resend then
			opts.resend()
		end
	end, "Resend request")

	vim.wo[body_win].wrap = true
	set_statusline(body_win, resp, spec)
	M.state.head_win, M.state.body_win = head_win, body_win
end

function M.toggle_headers()
	if is_valid(M.state.head_win) then
		pcall(vim.api.nvim_win_close, M.state.head_win, true)
		M.state.head_win = nil
	elseif M.state.last then
		M.show(M.state.last.resp, M.state.last.spec, M.state.last.opts)
	end
end

function M.toggle_zoom()
	M.state.zoomed = not M.state.zoomed
	if M.state.last then
		M.show(M.state.last.resp, M.state.last.spec, M.state.last.opts)
	end
end

function M.toggle_pretty()
	local d = M.state.display
	if not d or not is_valid(M.state.body_win) then
		return
	end
	if not d.json then
		vim.notify("Tuiter: body is not JSON", vim.log.levels.INFO, { title = "Tuiter" })
		return
	end
	M.state.pretty = not M.state.pretty
	local content = M.state.pretty and (d.pretty or d.raw) or d.raw
	local buf = vim.api.nvim_win_get_buf(M.state.body_win)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))
	vim.bo[buf].modifiable = false
end

function M.yank_body()
	if not is_valid(M.state.body_win) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(M.state.body_win)
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	vim.fn.setreg('"', text)
	vim.notify("Tuiter: response body copied", vim.log.levels.INFO, { title = "Tuiter" })
end

function M.save_body()
	if not is_valid(M.state.body_win) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(M.state.body_win)
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	local default = "tuiter-body-" .. os.date("%Y%m%d-%H%M%S") .. ".json"
	vim.ui.input({ prompt = "Save body to:", default = default }, function(path)
		if not path or path == "" then
			return
		end
		vim.fn.writefile(vim.split(text, "\n"), path)
		vim.notify("Tuiter: saved to " .. path, vim.log.levels.INFO, { title = "Tuiter" })
	end)
end

function M.mark(url, status)
	M.state.results[url] = status
end

function M.toggle()
	if is_valid(M.state.body_win) or is_valid(M.state.head_win) then
		M.close()
	elseif M.state.last then
		M.show(M.state.last.resp, M.state.last.spec, M.state.last.opts)
	else
		vim.notify("Tuiter: no response yet", vim.log.levels.INFO, { title = "Tuiter" })
	end
end

-- ---------------------------------------------------------------------------
-- Keymap help
-- ---------------------------------------------------------------------------

function M.toggle_help()
	if is_valid(M.state.help_win) then
		pcall(vim.api.nvim_win_close, M.state.help_win, true)
		M.state.help_win = nil
		return
	end
	local buf = mk_buf()
	local lines = {}
	for _, sec in ipairs(HELP_SECTIONS) do
		lines[#lines + 1] = "── " .. sec[1]:upper() .. " ──"
		lines[#lines + 1] = "  " .. sec[2]
		lines[#lines + 1] = ""
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	for i, sec in ipairs(HELP_SECTIONS) do
		vim.api.nvim_buf_add_highlight(buf, -1, "Title", (i - 1) * 3, 0, -1)
	end
	local cols, rows = vim.o.columns, vim.o.lines
	local width = math.min(90, cols - 8)
	local height = math.min(#lines + 2, rows - 4)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(2, math.floor((rows - height) / 2)),
		col = math.floor((cols - width) / 2),
		border = "rounded",
		style = "minimal",
		title = " tuiter help ",
		title_pos = "center",
	})
	buf_map(buf, "q", M.toggle_help, "Close help")
	buf_map(buf, "?", M.toggle_help, "Close help")
	M.state.help_win = win
end

-- ---------------------------------------------------------------------------
-- Request sidebar
-- ---------------------------------------------------------------------------

function M.sidebar_is_open()
	return is_valid(M.state.sidebar_win)
end

function M.close_sidebar()
	if is_valid(M.state.sidebar_win) then
		pcall(vim.api.nvim_win_close, M.state.sidebar_win, true)
	end
	M.state.sidebar_win, M.state.sidebar_buf = nil, nil
	M.state.sidebar_requests, M.state.sidebar_opts = {}, nil
end

--- Show the request list.
--- opts: { title, env, run = fn(spec), go_to = fn(lnum), copy_curl = fn(spec), run_all = fn() }
function M.show_sidebar(requests, opts)
	M.close_sidebar()
	if #requests == 0 then
		return
	end
	M.state.sidebar_requests, M.state.sidebar_opts = requests, opts

	-- favorites first, then the rest, preserving file order
	local entries = {}
	for _, r in ipairs(requests) do
		if M.state.favs[r.url] then
			entries[#entries + 1] = r
		end
	end
	for _, r in ipairs(requests) do
		if not M.state.favs[r.url] then
			entries[#entries + 1] = r
		end
	end

	local buf = mk_buf()
	local lines = {}
	for i, r in ipairs(entries) do
		local mark = M.state.results[r.url] and string.format("[%d]", M.state.results[r.url]) or "    "
		local star = M.state.favs[r.url] and "★" or " "
		local label = r.name ~= "" and r.name or r.url
		local url = r.name ~= "" and r.url or ""
		lines[#lines + 1] = string.format("%s %s %-6s %-24s %s", star, mark, r.method, trunc(label, 24), trunc(url, 20))
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	for i, r in ipairs(entries) do
		local status = M.state.results[r.url]
		if M.state.favs[r.url] then
			vim.api.nvim_buf_add_highlight(buf, -1, "TuiterStar", i - 1, 0, 1)
		end
		if status then
			vim.api.nvim_buf_add_highlight(buf, -1, status < 400 and "TuiterOk" or "TuiterError", i - 1, 2, 6)
		end
		vim.api.nvim_buf_add_highlight(buf, -1, METHOD_HL[r.method] or "Comment", i - 1, 7, 7 + #r.method)
	end
	vim.bo[buf].modifiable = false

	local title = opts.title and (" — " .. opts.title) or ""
	if opts.env then
		title = title .. " (env: " .. opts.env .. ")"
	end
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = 62,
		height = math.min(#lines + 2, vim.o.lines - 4),
		row = 2,
		col = 2,
		border = "rounded",
		style = "minimal",
		title = " requests" .. title .. " ",
		title_pos = "center",
	})
	vim.wo[win].statusline =
		"%#TuiterStatusHint# q=close  <CR>=run  g=go-to-file  *=favorite  a=run-all  c=copy-curl  ?=help %*"

	buf_map(buf, "q", M.close_sidebar, "Close request list")
	buf_map(buf, "?", M.toggle_help, "Show keymap help")
	buf_map(buf, "<CR>", function()
		local spec = entries[vim.api.nvim_win_get_cursor(0)[1]]
		if spec then
			M.close_sidebar()
			if opts.run then
				opts.run(spec)
			end
		end
	end, "Run request")
	buf_map(buf, "g", function()
		local spec = entries[vim.api.nvim_win_get_cursor(0)[1]]
		if spec and opts.go_to then
			opts.go_to(spec.line)
		end
	end, "Go to request in file")
	buf_map(buf, "*", function()
		local spec = entries[vim.api.nvim_win_get_cursor(0)[1]]
		if spec then
			M.toggle_fav(spec.url)
		end
	end, "Toggle favorite")
	buf_map(buf, "a", function()
		if opts.run_all then
			opts.run_all()
		end
	end, "Run all requests")
	buf_map(buf, "c", function()
		local spec = entries[vim.api.nvim_win_get_cursor(0)[1]]
		if spec and opts.copy_curl then
			opts.copy_curl(spec)
		end
	end, "Copy as curl")

	M.state.sidebar_win, M.state.sidebar_buf = win, buf
end

-- ---------------------------------------------------------------------------
-- Run-all summary
-- ---------------------------------------------------------------------------

--- results: { { spec = spec, resp = resp } } — shown with status colors.
function M.show_run_summary(results, opts)
	if is_valid(M.state.summary_win) then
		pcall(vim.api.nvim_win_close, M.state.summary_win, true)
	end
	local buf = mk_buf()
	local lines = {}
	for i, entry in ipairs(results) do
		local resp = entry.resp
		local ok = resp.ok and resp.status < 400
		local icon = ok and "✓" or "✗"
		local status = string.format(
			"%s %-3s %-6s %-24s · %dms · %s",
			icon,
			resp.status,
			entry.spec.method,
			trunc(entry.spec.name ~= "" and entry.spec.name or entry.spec.url, 24),
			(resp.time or 0) * 1000,
			fmt_size(resp.size)
		)
		lines[#lines + 1] = status
		vim.api.nvim_buf_add_highlight(buf, -1, ok and "TuiterOk" or "TuiterError", i - 1, 0, -1)
	end
	if #lines == 0 then
		lines = { "(no results)" }
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	local cols, rows = vim.o.columns, vim.o.lines
	local width = math.min(80, cols - 8)
	local height = math.min(#lines + 2, rows - 4)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(2, math.floor((rows - height) / 2)),
		col = math.floor((cols - width) / 2),
		border = "rounded",
		style = "minimal",
		title = " tuiter — run results ",
		title_pos = "center",
	})
	buf_map(buf, "q", function()
		pcall(vim.api.nvim_win_close, win, true)
		M.state.summary_win = nil
	end, "Close results")
	if opts then
		buf_map(buf, "<CR>", function()
			local i = vim.api.nvim_win_get_cursor(0)[1]
			local entry = results[i]
			if entry and opts.buf and vim.api.nvim_buf_is_valid(opts.buf) then
				pcall(vim.api.nvim_win_close, win, true)
				M.state.summary_win = nil
				vim.api.nvim_set_current_buf(opts.buf)
				vim.api.nvim_win_set_cursor(0, { entry.spec.line, 0 })
			end
		end, "Jump to request")
	end
	M.state.summary_win = win
end

return M
