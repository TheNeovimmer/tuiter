--- Response UI: Insomnia-style floating windows — a tab bar (Body | Headers |
--- Timeline) over a response viewer, plus the request sidebar, favorites,
--- zoom, copy-as-curl, run-all summary and keymap help.
local client = require("tuiter.client")

local M = {
	state = {
		head_win = nil, -- tab bar window
		body_win = nil, -- content window
		help_win = nil,
		summary_win = nil,
		last = nil, -- { resp, spec, opts } of the last shown response
		prev = nil, -- { resp, spec } of the previously shown response
		aux_win = nil,
		tab = 1, -- 1=body 2=headers 3=timeline
		pretty = true, -- pretty vs raw JSON body
		display = nil, -- { raw, pretty, json } of the shown body
		results = {}, -- url -> http status, shown as marks in the sidebar
		zoomed = false, -- content maximized (tab bar hidden)
		favs = {}, -- url -> true (persisted)
		filter = "", -- sidebar filter
		sidebar_win = nil,
		sidebar_buf = nil,
		sidebar_requests = {}, -- specs backing the current sidebar
		sidebar_entries = {}, -- entries currently listed (filtered)
		sidebar_opts = nil,
		marks = {}, -- buf -> { line -> extmark id } (inline result marks)
	},
}

M.mark_ns = vim.api.nvim_create_namespace("tuiter_marks")

local FAVS_FILE = vim.fn.stdpath("data") .. "/tuiter/favorites.json"

vim.api.nvim_set_hl(0, "TuiterOk", { link = "DiagnosticOk" })
vim.api.nvim_set_hl(0, "TuiterError", { link = "DiagnosticError" })
vim.api.nvim_set_hl(0, "TuiterRunning", { link = "Comment" })
vim.api.nvim_set_hl(0, "TuiterGet", { link = "DiagnosticOk" })
vim.api.nvim_set_hl(0, "TuiterPost", { link = "DiagnosticInfo" })
vim.api.nvim_set_hl(0, "TuiterPut", { link = "DiagnosticWarn" })
vim.api.nvim_set_hl(0, "TuiterPatch", { link = "DiagnosticWarn" })
vim.api.nvim_set_hl(0, "TuiterDelete", { link = "DiagnosticError" })
vim.api.nvim_set_hl(0, "TuiterStar", { default = true, fg = "#f0c674" })
vim.api.nvim_set_hl(0, "TuiterStatusOk", { default = true, fg = "#0d1117", bg = "#3fb950" })
vim.api.nvim_set_hl(0, "TuiterStatusErr", { default = true, fg = "#0d1117", bg = "#f85149" })
vim.api.nvim_set_hl(0, "TuiterStatusHint", { default = true, fg = "#9da5b4", bg = "#24292f" })
vim.api.nvim_set_hl(0, "TuiterUrl", { default = true, fg = "#79c0ff" })
vim.api.nvim_set_hl(0, "TuiterSection", { link = "Title" })
vim.api.nvim_set_hl(0, "TuiterVar", { default = true, fg = "#f0c674" })
vim.api.nvim_set_hl(0, "TuiterHeaderKey", { default = true, fg = "#79c0ff" })

local METHOD_HL = {
	GET = "TuiterGet",
	POST = "TuiterPost",
	PUT = "TuiterPut",
	PATCH = "TuiterPatch",
	DELETE = "TuiterDelete",
}

local HELP_SECTIONS = {
	{
		"sidebar",
		"q close  <CR> run (stays open)  g go-to-file  * favorite  / filter  e env  a run all  c copy curl  ? help",
	},
	{
		"response",
		"q close  1/2/3 or t tabs (body/headers/timeline)  p pretty/raw  y copy  c copy-curl  C copy-snippet  f save  z zoom  r resend  ? help",
	},
	{
		"buffer",
		"<leader>is/<CR> send  <leader>il sidebar  <leader>ia run all  <leader>ic cancel  <leader>ik help  ]r/[r next/prev  <leader>ih history  <leader>ie env  <leader>ir response  gx open URL  :TuiterCopyAs lang",
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
	-- body starts with { or [ (bare [ inside a class is escaped with %)
	return resp.body:match("^%s*[%[{]") ~= nil
end

local function content_type(resp)
	local ct = resp.headers:lower():match("content%-type:%s*([^;\r\n]*)") or ""
	return ct:gsub("^%s+", "")
end

local function body_filetype(resp)
	local ct = content_type(resp)
	if ct:match("json") then
		return "json"
	end
	if ct:match("html") then
		return "html"
	end
	if ct:match("xml") then
		return "xml"
	end
	if ct:match("css") then
		return "css"
	end
	if ct:match("javascript") or ct:match("ecmascript") then
		return "javascript"
	end
	return nil
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
-- Response windows (Insomnia-style: tab bar + content)
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

local function open_floats(tab_buf, body_buf, body_title, win_cfg)
	local cols, rows = vim.o.columns, vim.o.lines
	local col = float_col()
	local mh = (win_cfg or {}).max_height or 40
	local width = math.max(50, math.min((win_cfg or {}).width or 120, cols - col - 2))
	local zoomed = M.state.zoomed
	local head_win = nil
	local body_h = zoomed and math.min(rows - 6, math.max(mh, 60)) or math.max(5, math.min(mh, rows - 12))
	if not zoomed then
		head_win = vim.api.nvim_open_win(tab_buf, false, {
			relative = "editor",
			width = width,
			height = 1,
			row = 2,
			col = col,
			border = "none",
			style = "minimal",
		})
	end
	local body_win = vim.api.nvim_open_win(body_buf, true, {
		relative = "editor",
		width = width,
		height = body_h,
		row = zoomed and 2 or 3,
		col = col,
		border = "rounded",
		style = "minimal",
		title = " " .. body_title .. " ",
		title_pos = "center",
	})
	return head_win, body_win
end

local TAB_NAMES = { "Body", "Headers", "Timeline", "Tests" }

local function render_tabs()
	local resp, spec = M.state.last.resp, M.state.last.spec
	if not is_valid(M.state.head_win) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(M.state.head_win)
	local width = vim.api.nvim_win_get_width(M.state.head_win)
	local line = " "
	for i, name in ipairs(TAB_NAMES) do
		if i > 1 then
			line = line .. " | "
		end
		line = line .. name
	end
	local reason = resp.headers:match("^HTTP/%S+ %d+ ([^\r\n]*)") or ""
	local ok = resp.ok and resp.status < 400
	local status
	if resp.status > 0 then
		status = string.format(
			"HTTP %d%s · %dms · %s",
			resp.status,
			reason ~= "" and (" " .. reason) or "",
			(resp.time or 0) * 1000,
			fmt_size(resp.size)
		)
	elseif resp.error and resp.error ~= "" then
		status = "✗ " .. trunc(resp.error, 60)
	else
		status = "no response"
	end
	if #line + #status + 3 < width then
		line = line .. string.rep(" ", width - #line - #status) .. status
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
	vim.bo[buf].modifiable = false
	local pos = 1 -- 0-based col where each tab starts
	for i, name in ipairs(TAB_NAMES) do
		local seg = (i > 1 and " | " or " ") .. name
		vim.api.nvim_buf_add_highlight(buf, -1, i == M.state.tab and "TabLineSel" or "TabLine", 0, pos, pos + #seg)
		pos = pos + #seg
	end
	local stpos = line:find(status, 1, true)
	if stpos then
		vim.api.nvim_buf_add_highlight(buf, -1, ok and "TuiterOk" or "TuiterError", 0, stpos - 1, stpos - 1 + #status)
	end
end

--- Rows for the Insomnia-style "Timeline" tab (from curl timing data).
function M.timeline_lines(resp)
	local ts = resp.times or {}
	local function ms(v)
		return v and math.floor(v * 1000) or nil
	end
	local function delta(a, b)
		if a and b and b >= a then
			return b - a
		end
		return nil
	end
	local rows = {
		{ "DNS lookup", ms(ts.namelookup) },
		{ "TCP connect", ms(delta(ts.namelookup, ts.connect)) },
		{ "TLS handshake", ms(delta(ts.connect, ts.appconnect)) },
		{ "Request sent", ms(delta(ts.appconnect, ts.pretransfer)) },
		{ "Waiting (TTFB)", ms(delta(ts.pretransfer, ts.starttransfer)) },
		{ "Download", ms(delta(ts.starttransfer, ts.total)) },
		{ "Total", ms(ts.total) },
	}
	local lines, w = {}, 22
	for _, r in ipairs(rows) do
		lines[#lines + 1] = ("%-" .. w .. "s %s"):format(r[1], r[2] and (r[2] .. "ms") or "–")
	end
	lines[#lines + 1] = ("-"):rep(w + 6)
	lines[#lines + 1] = ("%-" .. w .. "s %s"):format("Size", fmt_size(resp.size))
	lines[#lines + 1] = ("%-" .. w .. "s %s"):format("Redirects", tostring(resp.redirects or 0))
	local proto = resp.headers:match("^(HTTP/%S+)") or ""
	if proto ~= "" then
		lines[#lines + 1] = ("%-" .. w .. "s %s"):format("Protocol", proto)
	end
	local ct = content_type(resp)
	if ct ~= "" then
		lines[#lines + 1] = ("%-" .. w .. "s %s"):format("Content type", ct)
	end
	return lines
end

local function render_content()
	if not is_valid(M.state.body_win) or not M.state.last then
		return
	end
	local buf = vim.api.nvim_win_get_buf(M.state.body_win)
	local resp = M.state.last.resp
	vim.bo[buf].modifiable = true
	if M.state.tab == 1 then
		local d = M.state.display
		local content = d.raw
		if d.json and M.state.pretty and d.pretty then
			content = d.pretty
		end
		if resp.error and resp.error ~= "" then
			content = "✗ " .. resp.error
		elseif content == "" then
			content = "(empty body)"
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))
		local ft = d.json and "json" or body_filetype(resp)
		if ft then
			vim.bo[buf].filetype = ft
			pcall(vim.treesitter.start, buf, ft)
		end
		if d.json then
			vim.wo[M.state.body_win].foldmethod = "expr"
			vim.wo[M.state.body_win].foldexpr = "v:lua.vim.treesitter.foldexpr()"
			vim.wo[M.state.body_win].foldlevel = 99
		else
			vim.wo[M.state.body_win].foldmethod = "manual"
		end
	elseif M.state.tab == 2 then
		local hlines = resp.headers ~= "" and vim.split(resp.headers, "\n") or { "(no headers)" }
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, hlines)
		vim.bo[buf].filetype = "text"
		vim.wo[M.state.body_win].foldmethod = "manual"
		for i, hl in ipairs(hlines) do
			local key = hl:match("^([^:]+):")
			if key then
				vim.api.nvim_buf_add_highlight(buf, -1, "TuiterHeaderKey", i - 1, 0, #key)
			end
		end
	elseif M.state.tab == 3 then
		local tlines = M.timeline_lines(resp)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, tlines)
		vim.bo[buf].filetype = "text"
		vim.wo[M.state.body_win].foldmethod = "manual"
		for i, tl in ipairs(tlines) do
			vim.api.nvim_buf_add_highlight(buf, -1, "Comment", i - 1, 22, -1)
		end
	else
		-- Tests tab: render # @test assertions
		local tlines, n = {}, 0
		local tests = resp.tests or {}
		if #tests == 0 then
			tlines[1] = "(no # @test assertions)"
		else
			for _, te in ipairs(tests) do
				n = n + 1
				local icon = te.pass and "✓" or "✗"
				tlines[n] = icon .. " " .. (te.expr or "")
				if te.actual ~= nil then
					tlines[n] = tlines[n] .. "   · got: " .. trunc(fmt_actual(te.actual), 60)
				elseif te.error then
					tlines[n] = tlines[n] .. "   · " .. te.error
				end
			end
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, tlines)
		vim.bo[buf].filetype = "text"
		vim.wo[M.state.body_win].foldmethod = "manual"
		for i, te in ipairs(tests) do
			vim.api.nvim_buf_add_highlight(buf, -1, te.pass and "TuiterOk" or "TuiterError", i - 1, 0, -1)
		end
	end
	vim.bo[buf].modifiable = false
end

local function fmt_actual(v)
	if type(v) == "table" then
		v = vim.json.encode(v)
	end
	-- flatten multi-line bodies (e.g. failed `contains`) for the one-line summary
	return tostring(v):gsub("[\r\n]+", " ")
end

local function set_statusline(win, resp, spec)
	local reason = resp.headers:match("^HTTP/%S+ %d+ ([^\r\n]*)") or ""
	local ok = resp.ok and resp.status < 400
	local hl = ok and "TuiterStatusOk" or "TuiterStatusErr"
	local env = spec.env and ("   env: " .. spec.env) or ""
	local status
	if resp.status > 0 then
		status =
			string.format("HTTP %d %s · %dms · %s", resp.status, reason, (resp.time or 0) * 1000, fmt_size(resp.size))
	elseif resp.error and resp.error ~= "" then
		status = "✗ " .. resp.error
	else
		status = "no response"
	end
	vim.wo[win].statusline = string.format("%%#%s# tuiter  %s %s  ·  %s%s %%*", hl, spec.method, spec.url, status, env)
end

--- Show a response. opts: { resend = fn, copy_curl = fn }
function M.show(resp, spec, opts)
	opts = opts or {}
	M.state.prev = M.state.last -- save for diff-vs-previous
	M.state.last = { resp = resp, spec = spec, opts = opts }
	if opts.buf then
		spec.buf = spec.buf or opts.buf
	end
	M.mark_response(spec, resp)
	if resp.error and resp.error ~= "" and resp.status == 0 then
		vim.notify("Tuiter: " .. resp.error, vim.log.levels.WARN, { title = "Tuiter" })
	end
	M.close()

	local json = is_json(resp)
	local pretty = json and client.pretty_json(resp.body) or nil
	M.state.pretty = json and pretty ~= nil
	M.state.display = { raw = resp.body, pretty = pretty, json = json }

	local tab_buf = mk_buf()
	local body_buf = mk_buf()
	local env = spec.env and ("(env: " .. spec.env .. ")") or ""
	local head_win, body_win =
		open_floats(tab_buf, body_buf, string.format("%s %s %s", spec.method, spec.url, env), opts.windows)

	for _, b in ipairs({ tab_buf, body_buf }) do
		buf_map(b, "q", M.close, "Close response")
		buf_map(b, "t", M.cycle_tab, "Next tab")
		buf_map(b, "1", function()
			M.set_tab(1)
		end, "Body tab")
		buf_map(b, "2", function()
			M.set_tab(2)
		end, "Headers tab")
		buf_map(b, "3", function()
			M.set_tab(3)
		end, "Timeline tab")
	end
	buf_map(body_buf, "4", function()
		M.set_tab(4)
	end, "Tests tab")
	buf_map(body_buf, "p", M.toggle_pretty, "Toggle pretty/raw body")
	buf_map(body_buf, "y", M.yank_body, "Copy current tab")
	buf_map(body_buf, "f", M.save_body, "Save body to file")
	buf_map(body_buf, "z", M.toggle_zoom, "Zoom response")
	buf_map(body_buf, "?", M.toggle_help, "Show keymap help")
	buf_map(body_buf, "c", function()
		if opts.copy_curl then
			opts.copy_curl()
		end
	end, "Copy as curl")
	buf_map(body_buf, "C", function()
		if opts.copy_code then
			opts.copy_code()
		end
	end, "Copy as code snippet")
	buf_map(body_buf, "r", function()
		if opts.resend then
			opts.resend()
		end
	end, "Resend request")
	buf_map(body_buf, "D", M.diff_prev, "Diff against previous response")
	buf_map(body_buf, "J", M.jq_filter, "Filter body through jq")
	buf_map(body_buf, "o", M.open_in_tab, "Open response in a new tab")
	buf_map(body_buf, "]k", function()
		M.jump_key(1)
	end, "Next JSON key")
	buf_map(body_buf, "[k", function()
		M.jump_key(-1)
	end, "Previous JSON key")

	vim.wo[body_win].wrap = true
	set_statusline(body_win, resp, spec)
	M.state.head_win, M.state.body_win = head_win, body_win
	render_tabs()
	render_content()
end

--- Switch the response tab (1=Body, 2=Headers, 3=Timeline).
function M.set_tab(n)
	if not M.state.last then
		return
	end
	M.state.tab = n
	render_tabs()
	render_content()
	if is_valid(M.state.body_win) then
		vim.api.nvim_set_current_win(M.state.body_win)
	end
end

function M.cycle_tab()
	M.set_tab(M.state.tab % #TAB_NAMES + 1)
end

function M.toggle_zoom()
	M.state.zoomed = not M.state.zoomed
	if M.state.last then
		M.show(M.state.last.resp, M.state.last.spec, M.state.last.opts)
	end
end

function M.toggle_pretty()
	if not M.state.display or not is_valid(M.state.body_win) then
		return
	end
	if not M.state.display.json then
		vim.notify("Tuiter: body is not JSON", vim.log.levels.INFO, { title = "Tuiter" })
		return
	end
	if M.state.tab ~= 1 then
		M.set_tab(1)
	end
	M.state.pretty = not M.state.pretty
	render_content()
end

function M.yank_body()
	if not is_valid(M.state.body_win) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(M.state.body_win)
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	vim.fn.setreg('"', text)
	vim.notify("Tuiter: " .. TAB_NAMES[M.state.tab]:lower() .. " copied", vim.log.levels.INFO, { title = "Tuiter" })
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

--- Mark the request line as in-flight with a "running" indicator. The mark
--- is stored in the same table as result marks, so mark_response replaces it
--- when the response lands (instant feedback instead of silence while waiting).
function M.mark_running(spec)
	local buf = spec.buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) or not spec.line or spec.line < 1 then
		return
	end
	local line = spec.line - 1
	local marks = M.state.marks[buf]
	if not marks then
		marks = {}
		M.state.marks[buf] = marks
	end
	if marks[line] then
		pcall(vim.api.nvim_buf_del_extmark, buf, M.mark_ns, marks[line])
	end
	marks[line] = vim.api.nvim_buf_set_extmark(buf, M.mark_ns, line, 0, {
		virt_text = { { "↻ running…", "TuiterRunning" } },
		virt_text_pos = "eol",
		hl_mode = "combine",
	})
end

--- Mark the request line in its source buffer with the last response
--- status as inline virtual text (and refresh the sidebar status map).
--- rest.nvim/httpyac-style: `✓ 200 · 45ms` / `✗ 404 · 12ms` at EOL.
function M.mark_response(spec, resp)
	M.mark(spec.url, resp.status)
	local buf = spec.buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) or not spec.line or spec.line < 1 then
		return
	end
	local failed = not resp.ok or resp.status >= 400 or (resp.failures or 0) > 0
	local text
	if resp.status > 0 then
		text = string.format("%s %d · %dms", failed and "✗" or "✓", resp.status, (resp.time or 0) * 1000)
	else
		text = "✗ error"
	end
	local line = spec.line - 1
	local marks = M.state.marks[buf]
	if not marks then
		marks = {}
		M.state.marks[buf] = marks
	end
	if marks[line] then
		pcall(vim.api.nvim_buf_del_extmark, buf, M.mark_ns, marks[line])
	end
	marks[line] = vim.api.nvim_buf_set_extmark(buf, M.mark_ns, line, 0, {
		virt_text = { { text, failed and "TuiterError" or "TuiterOk" } },
		virt_text_pos = "eol",
		hl_mode = "combine",
	})
end

-- ---------------------------------------------------------------------------
-- Response helpers: diff-vs-previous, jq filter, open-in-tab, JSON navigation
-- ---------------------------------------------------------------------------

local function close_aux()
	if is_valid(M.state.aux_win) then
		pcall(vim.api.nvim_win_close, M.state.aux_win, true)
	end
	M.state.aux_win = nil
end

local function open_aux(title, lines, hl_line)
	close_aux()
	local buf = mk_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	local cols, rows = vim.o.columns, vim.o.lines
	local width = math.min(100, cols - 6)
	local height = math.min(#lines + 2, rows - 4)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(2, math.floor((rows - height) / 2)),
		col = math.floor((cols - width) / 2),
		border = "rounded",
		style = "minimal",
		title = " " .. title .. " ",
		title_pos = "center",
	})
	buf_map(buf, "q", close_aux, "Close")
	for i, line in ipairs(lines) do
		if hl_line then
			local hl = hl_line(line)
			if hl then
				vim.api.nvim_buf_add_highlight(buf, -1, hl, i - 1, 0, -1)
			end
		end
	end
	M.state.aux_win = win
end

local function pretty_or_raw(body)
	local p = client.pretty_json(body)
	return (p or body or "") .. "\n"
end

--- Diff the current response body against the previously shown response.
---`D` in the response window.
function M.diff_prev()
	local cur, prev = M.state.last, M.state.prev
	if not cur or not prev then
		vim.notify("Tuiter: no previous response to diff against", vim.log.levels.INFO, { title = "Tuiter" })
		return
	end
	local a, b = pretty_or_raw(prev.resp.body), pretty_or_raw(cur.resp.body)
	local ok, diff = pcall(vim.diff, a, b)
	if not ok or not diff then
		vim.notify("Tuiter: could not diff bodies", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	local lines = vim.split(diff, "\n", { plain = true })
	for i = #lines, 1, -1 do
		if lines[i] == "" then
			table.remove(lines, i)
		end
	end
	open_aux("diff — previous vs current (“" .. trunc(prev.spec.url, 30) .. "”)", lines, function(line)
		if line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
			return "diffDeleted"
		elseif line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
			return "diffAdded"
		end
		return nil
	end)
end

--- Pipe the current response body through jq (`J`). Requires jq on PATH.
function M.jq_filter()
	local last = M.state.last
	if not last then
		return
	end
	if vim.fn.executable("jq") == 0 then
		vim.notify("Tuiter: jq not found on PATH", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	vim.ui.input({ prompt = "jq filter (body is piped to jq):", default = "." }, function(expr)
		if not expr or expr == "" then
			return
		end
		local out = vim.fn.systemlist({ "jq", "-r", expr }, last.resp.body)
		open_aux("jq: " .. trunc(expr, 40), out)
		vim.notify("Tuiter: jq filter applied", vim.log.levels.INFO, { title = "Tuiter" })
	end)
end

--- Open the current response tab's content in a new tab (editable buffer).
function M.open_in_tab()
	local last = M.state.last
	if not last or not is_valid(M.state.body_win) then
		return
	end
	local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(M.state.body_win), 0, -1, false), "\n")
	local buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_buf_set_name(buf, "tuiter-response-" .. os.date("%H%M%S"))
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
	local ft = M.state.display and M.state.display.json and "json" or body_filetype(last.resp)
	if ft then
		vim.bo[buf].filetype = ft
	end
	vim.api.nvim_set_current_tabpage(vim.api.nvim_create_tabpage())
	vim.api.nvim_set_current_buf(buf)
end

--- Jump to the next/previous top-level JSON key in the pretty body tab.
function M.jump_key(dir)
	local body_win = M.state.body_win
	if not is_valid(body_win) or M.state.tab ~= 1 or not M.state.display or not M.state.display.json then
		return
	end
	local buf = vim.api.nvim_win_get_buf(body_win)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local keys = {}
	for i, line in ipairs(lines) do
		if line:match('^%s%s"') or line:match("^%s%s%d:") then
			keys[#keys + 1] = i
		end
	end
	if #keys == 0 then
		return
	end
	local cur = vim.api.nvim_win_get_cursor(body_win)[1]
	local next_key
	for _, k in ipairs(keys) do
		if (dir > 0 and k > cur) or (dir < 0 and k < cur) then
			next_key = k
			break
		end
	end
	if not next_key then
		next_key = dir > 0 and keys[1] or keys[#keys]
	end
	vim.api.nvim_win_set_cursor(body_win, { next_key, 0 })
end

-- ---------------------------------------------------------------------------
-- Streaming response (SSE / `# @stream`)
-- ---------------------------------------------------------------------------

local stream_win = nil -- held here to avoid clashing with the response floats

--- Open a streaming view for a request; chunks are appended via stream_chunk.
function M.open_stream(spec)
	if is_valid(stream_win) then
		pcall(vim.api.nvim_win_close, stream_win, true)
	end
	local buf = mk_buf()
	vim.bo[buf].filetype = "text"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "streaming: " .. spec.method .. " " .. spec.url .. "…" })
	vim.bo[buf].modifiable = false
	local cols, rows = vim.o.columns, vim.o.lines
	local width = math.min(100, cols - 6)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = math.min(rows - 6, 40),
		row = 2,
		col = math.max(2, (cols - width) / 2),
		border = "rounded",
		style = "minimal",
		title = " streaming — " .. trunc(spec.url, 30) .. " ",
		title_pos = "center",
	})
	buf_map(buf, "q", function()
		pcall(vim.api.nvim_win_close, win, true)
		stream_win = nil
	end, "Close stream")
	stream_win = win
end

--- Append a chunk to the streaming view (also cancelled via M.state cancel).
function M.stream_chunk(data)
	if not is_valid(stream_win) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(stream_win)
	local lines = vim.split(data, "\n", { plain = true })
	-- keep a trailing empty line if data ends in newline
	if data:sub(-1) == "\n" then
		lines[#lines + 1] = ""
	end
	vim.bo[buf].modifiable = true
	local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local tail = cur[#cur]
	if #lines > 0 and tail and tail ~= "" and lines[1] ~= "" then
		cur[#cur] = tail .. lines[1]
		table.remove(lines, 1)
	end
	local final = {}
	for i, l in ipairs(cur) do
		final[i] = l
	end
	for _, l in ipairs(lines) do
		final[#final + 1] = l
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, final)
	vim.bo[buf].modifiable = false
	vim.api.nvim_win_set_cursor(stream_win, { math.max(1, #final - 1), 0 })
end

--- Mark the stream as finished.
function M.stream_end(code)
	if not is_valid(stream_win) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(stream_win)
	vim.bo[buf].modifiable = true
	local final = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	final[#final + 1] = ""
	final[#final + 1] = "── end of stream (exit code " .. tostring(code) .. ") ──"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, final)
	vim.bo[buf].modifiable = false
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
	local width = math.min(100, cols - 8)
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
	M.state.sidebar_requests, M.state.sidebar_entries, M.state.sidebar_opts = {}, {}, nil
end

local function matches_filter(r, f)
	if f == "" then
		return true
	end
	local hay = (r.method .. " " .. r.name .. " " .. r.url):lower()
	return hay:find(f:lower(), 1, true) ~= nil
end

local function sidebar_entries(requests)
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
	local f = M.state.filter
	if f == "" then
		return entries
	end
	local filtered = {}
	for _, r in ipairs(entries) do
		if matches_filter(r, f) then
			filtered[#filtered + 1] = r
		end
	end
	return filtered
end

--- Set the sidebar filter ("" clears). Re-renders the list.
function M.set_filter(text)
	M.state.filter = text or ""
	if is_valid(M.state.sidebar_win) then
		M.show_sidebar(M.state.sidebar_requests, M.state.sidebar_opts)
	end
end

--- Show the request list.
--- opts: { title, env, run = fn(spec), go_to = fn(lnum), copy_curl = fn(spec), run_all = fn() }
function M.show_sidebar(requests, opts)
	M.close_sidebar()
	if #requests == 0 then
		return
	end
	M.state.sidebar_requests, M.state.sidebar_opts = requests, opts
	local entries = sidebar_entries(requests)
	M.state.sidebar_entries = entries

	local buf = mk_buf()
	local lines = {}
	for _, r in ipairs(entries) do
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
	if M.state.filter ~= "" then
		title = title .. "  filter: " .. M.state.filter
	end
	title = " requests (" .. #entries .. ")" .. title
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = (opts.windows and opts.windows.sidebar_width) or 62,
		height = math.min(#lines + 2, vim.o.lines - 4),
		row = 2,
		col = 2,
		border = "rounded",
		style = "minimal",
		title = title .. " ",
		title_pos = "center",
	})
	vim.wo[win].statusline =
		"%#TuiterStatusHint# q=close  <CR>=run  g=go-to-file  *=favorite  /=filter  e=env  a=run-all  c=copy-curl  ?=help %*"

	buf_map(buf, "q", M.close_sidebar, "Close request list")
	buf_map(buf, "?", M.toggle_help, "Show keymap help")
	buf_map(buf, "e", function()
		if opts.switch_env then
			opts.switch_env()
		end
	end, "Switch environment")
	buf_map(buf, "/", function()
		vim.ui.input({ prompt = "Filter requests (empty clears):", default = M.state.filter }, function(f)
			M.set_filter(f)
		end)
	end, "Filter requests")
	buf_map(buf, "<CR>", function()
		-- keep the sidebar open, like Insomnia's collection list
		local spec = M.state.sidebar_entries[vim.api.nvim_win_get_cursor(0)[1]]
		if spec and opts.run then
			opts.run(spec)
		end
	end, "Run request")
	buf_map(buf, "g", function()
		local spec = M.state.sidebar_entries[vim.api.nvim_win_get_cursor(0)[1]]
		if spec and opts.go_to then
			opts.go_to(spec.line)
		end
	end, "Go to request in file")
	buf_map(buf, "*", function()
		local spec = M.state.sidebar_entries[vim.api.nvim_win_get_cursor(0)[1]]
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
		local spec = M.state.sidebar_entries[vim.api.nvim_win_get_cursor(0)[1]]
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
		if entry.skipped then
			local label = entry.spec.name ~= "" and entry.spec.name or entry.spec.url
			lines[#lines + 1] = string.format("⏭  %-6s %s", entry.spec.method or "", trunc(label, 24))
			vim.api.nvim_buf_add_highlight(buf, -1, "Comment", #lines - 1, 0, -1)
		else
			local resp = entry.resp
			local failed = (resp.failures or 0) > 0
			local ok = (resp.ok and resp.status < 400) and not failed
			local icon = ok and "✓" or "✗"
			local tag = failed and " (tests failed)" or ""
			local status = string.format(
				"%s %-3s %-6s %-24s · %dms · %s%s",
				icon,
				resp.status,
				entry.spec.method,
				trunc(entry.spec.name ~= "" and entry.spec.name or entry.spec.url, 24),
				(resp.time or 0) * 1000,
				fmt_size(resp.size),
				tag
			)
			lines[#lines + 1] = status
			local hl = ok and "TuiterOk" or "TuiterError"
			local line_no = #lines
			vim.api.nvim_buf_add_highlight(buf, -1, hl, line_no - 1, 0, -1)
			-- indent failed assertions under their request
			if resp.tests and #resp.tests > 0 then
				for _, te in ipairs(resp.tests) do
					local mark = te.pass and "✓" or "✗"
					local l = "    " .. mark .. " " .. te.expr
					if te.actual ~= nil then
						l = l .. "  · got: " .. trunc(fmt_actual(te.actual), 50)
					end
					lines[#lines + 1] = l
					vim.api.nvim_buf_add_highlight(buf, -1, te.pass and "Comment" or "TuiterError", #lines - 1, 0, -1)
				end
			end
		end
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
