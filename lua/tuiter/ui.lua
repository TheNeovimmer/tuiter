--- Response UI: Insomnia-style floating windows — a tab bar (Body | Headers |
--- Timeline) over a response viewer, plus the request sidebar, favorites,
--- zoom, copy-as-curl, run-all summary and keymap help.
local client = require("tuiter.client")

local M = {
	state = {
		head_win = nil, -- tab bar window (float mode)
		body_win = nil, -- content window (float mode)
		help_win = nil,
		summary_win = nil,
		last = nil, -- { resp, spec, opts } of the last shown response
		prev = nil, -- { resp, spec } of the previously shown response
		aux_win = nil,
		tab = 1, -- 1=body 2=headers 3=timeline
		pretty = true, -- pretty vs raw JSON body
		display = nil, -- { raw, pretty, json } of the shown body
		results = {}, -- url -> http status, shown as marks in the sidebar
		resp_detail = {}, -- url -> { time, size, error } for the sidebar marks
		zoomed = false, -- content maximized (tab bar hidden)
		favs = {}, -- url -> true (persisted)
		filter = "", -- sidebar filter
		sidebar_win = nil,
		sidebar_buf = nil,
		sidebar_requests = {}, -- specs backing the current sidebar
		sidebar_entries = {}, -- entries currently listed (filtered)
		sidebar_opts = nil,
		marks = {}, -- buf -> { line -> extmark id } (inline result marks)
		resp_split_win = nil, -- response split window (split mode)
		resp_split_buf = nil, -- response split buffer (split mode)
		resp_tab_win = nil, -- response tab bar split (split mode)
		resp_tab_buf = nil, -- response tab bar buffer (split mode)
		spinner_win = nil, -- loading spinner window
		spinner_buf = nil,
		spinner_timer = nil, -- uv timer for spinner animation
		spinner_idx = 1,
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
-- UI polish highlights
vim.api.nvim_set_hl(0, "TuiterTabActive", { default = true, bold = true })
vim.api.nvim_set_hl(0, "TuiterTabInactive", { default = true, fg = "#636e7b" })
vim.api.nvim_set_hl(0, "TuiterBadge2xx", { default = true, fg = "#0d1117", bg = "#3fb950", bold = true })
vim.api.nvim_set_hl(0, "TuiterBadge3xx", { default = true, fg = "#0d1117", bg = "#d29922", bold = true })
vim.api.nvim_set_hl(0, "TuiterBadge4xx", { default = true, fg = "#0d1117", bg = "#f85149", bold = true })
vim.api.nvim_set_hl(0, "TuiterBadge5xx", { default = true, fg = "#f0f6fc", bg = "#da3633", bold = true })
vim.api.nvim_set_hl(0, "TuiterMethodPill", { default = true, fg = "#0d1117", bold = true })
vim.api.nvim_set_hl(0, "TuiterFooter", { default = true, fg = "#636e7b", bg = "#161b22" })
vim.api.nvim_set_hl(0, "TuiterFooterKey", { default = true, fg = "#79c0ff", bg = "#161b22" })
vim.api.nvim_set_hl(0, "TuiterSpinner", { link = "Constant" })
vim.api.nvim_set_hl(0, "TuiterSep", { default = true, fg = "#30363d" })

local METHOD_HL = {
	GET = "TuiterGet",
	POST = "TuiterPost",
	PUT = "TuiterPut",
	PATCH = "TuiterPatch",
	DELETE = "TuiterDelete",
}

local METHOD_BG = {
	GET = "#3fb950",
	POST = "#79c0ff",
	PUT = "#d29922",
	PATCH = "#d29922",
	DELETE = "#f85149",
}

--- Return a status badge highlight group based on HTTP status code.
local function status_badge_hl(code)
	if code >= 200 and code < 300 then
		return "TuiterBadge2xx"
	elseif code >= 300 and code < 400 then
		return "TuiterBadge3xx"
	elseif code >= 400 and code < 500 then
		return "TuiterBadge4xx"
	else
		return "TuiterBadge5xx"
	end
end

--- Render a compact status badge: " 200 " with colored background.
local function fmt_status_badge(code)
	return string.format(" %d ", code)
end

local function is_valid(w)
	return w and vim.api.nvim_win_is_valid(w)
end

local function mk_buf()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	return buf
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

-- ---------------------------------------------------------------------------
-- Loading spinner
-- ---------------------------------------------------------------------------

local SPINNERS = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Show a loading spinner in a small float. Displays "METHOD url …" with an
--- animated spinner character. Auto-closes when the response arrives.
function M.show_spinner(spec)
	M.close_spinner()
	local buf = mk_buf()
	vim.bo[buf].modifiable = true
	local line = string.format("  %s %s …", spec.method or "?", trunc(spec.url or "", 50))
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
	vim.bo[buf].modifiable = false
	local width = #line + 2
	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		width = width,
		height = 1,
		row = vim.o.lines - 3,
		col = vim.o.columns - width - 2,
		border = "none",
		style = "minimal",
		focusable = false,
		zindex = 100,
	})
	vim.wo[win].winblend = 10
	M.state.spinner_win, M.state.spinner_buf = win, buf
	-- animate
	M.state.spinner_idx = 1
	M.state.spinner_timer = vim.uv.new_timer()
	M.state.spinner_timer:start(0, 80, vim.schedule_wrap(function()
		if not is_valid(win) then
			M.close_spinner()
			return
		end
		M.state.spinner_idx = (M.state.spinner_idx % #SPINNERS) + 1
		local ch = SPINNERS[M.state.spinner_idx]
		pcall(vim.api.nvim_buf_set_lines, buf, 0, 1, false, {
			string.format(" %s %s %s", ch, spec.method or "?", trunc(spec.url or "", 50))
		})
	end))
end

--- Close the loading spinner.
function M.close_spinner()
	if M.state.spinner_timer then
		pcall(M.state.spinner_timer.stop, M.state.spinner_timer)
		pcall(M.state.spinner_timer.close, M.state.spinner_timer)
		M.state.spinner_timer = nil
	end
	if is_valid(M.state.spinner_win) then
		pcall(vim.api.nvim_win_close, M.state.spinner_win, true)
	end
	M.state.spinner_win, M.state.spinner_buf = nil, nil
end

local HELP_SECTIONS = {
	{
		"sidebar",
		"q close  <CR> run (stays open)  g go-to-file  * favorite  / filter  e env  a run all  c copy curl  ? help",
	},
	{
		"response",
		"q close  1/2/3/4 or t tabs (body/headers/timeline/tests)  p pretty/raw  y copy  c copy-curl  C copy-snippet  f save  z zoom  r resend  D diff  J jq  o open-in-tab  ]k/[k json keys  P json-path  V json-value  U copy-url  gx open URL  ? help",
	},
	{
		"buffer",
		"<leader>is/<CR> send  <leader>iv vars  <leader>il sidebar  <leader>ia run all  <leader>ic cancel  <leader>ik help  <leader>ir response toggle  ]r/[r next/prev  <leader>ih history  <leader>ie env  gx open URL  :TuiterCopyAs lang",
	},
}

local function layout_mode()
	local ok, cfg = pcall(require, "tuiter")
	if ok and cfg.opts then
		local o = cfg.opts()
		return (o.windows or {}).layout or "float"
	end
	return "float"
end

local function is_compact()
	local ok, cfg = pcall(require, "tuiter")
	if ok and cfg.opts then
		local o = cfg.opts()
		return (o.windows or {}).compact or false
	end
	return false
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
	M.close_spinner()
	-- close float windows
	for _, w in ipairs({ M.state.head_win, M.state.body_win }) do
		if is_valid(w) then
			pcall(vim.api.nvim_win_close, w, true)
		end
	end
	M.state.head_win, M.state.body_win = nil, nil
	-- close split windows
	if is_valid(M.state.resp_tab_win) then
		pcall(vim.api.nvim_win_close, M.state.resp_tab_win, true)
	end
	if is_valid(M.state.resp_split_win) then
		pcall(vim.api.nvim_win_close, M.state.resp_split_win, true)
	end
	M.state.resp_tab_win, M.state.resp_tab_buf = nil, nil
	M.state.resp_split_win, M.state.resp_split_buf = nil, nil
end

--- Close only the response (split or float), leaving the sidebar open.
function M.close_response()
	if is_valid(M.state.resp_split_win) then
		pcall(vim.api.nvim_win_close, M.state.resp_split_win, true)
		M.state.resp_split_win, M.state.resp_split_buf = nil, nil
		return
	end
	M.close()
end

--- Toggle response visibility (split mode: toggle the response split).
function M.toggle_response()
	if is_valid(M.state.resp_split_win) then
		M.close_response()
	elseif M.state.last then
		M.show(M.state.last.resp, M.state.last.spec, M.state.last.opts)
	else
		vim.notify("Tuiter: no response yet", vim.log.levels.INFO, { title = "Tuiter" })
	end
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
	-- method dot + name
	local method = spec.method or ""
	local method_dot = method ~= "" and ("● ") or ""
	local line = " " .. method_dot .. method .. "  "
	-- tab names (active = uppercase, inactive = lowercase)
	for i, name in ipairs(TAB_NAMES) do
		if i > 1 then
			line = line .. " │ "
		end
		line = line .. (i == M.state.tab and name:upper() or name:lower())
	end
	-- status badge + timing
	local badge = ""
	if resp.status > 0 then
		badge = fmt_status_badge(resp.status)
	elseif resp.error and resp.error ~= "" then
		badge = " ERR "
	end
	local timing = string.format("%dms", (resp.time or 0) * 1000)
	local size = fmt_size(resp.size)
	local right = badge .. " " .. timing .. " · " .. size
	if #line + #right + 3 < width then
		line = line .. string.rep(" ", width - #line - #right) .. right
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
	vim.bo[buf].modifiable = false
	-- highlight method dot + name
	if method ~= "" then
		local dot_pos = line:find("●", 1, true)
		if dot_pos then
			vim.api.nvim_buf_add_highlight(buf, -1, METHOD_HL[method] or "Comment", 0, dot_pos - 1, dot_pos + 1)
		end
		local method_end = line:find(method, dot_pos and dot_pos or 1, true)
		if method_end then
			vim.api.nvim_buf_add_highlight(buf, -1, METHOD_HL[method] or "Comment", 0, method_end - 1, method_end - 1 + #method)
		end
	end
	-- highlight tab names
	local pos = 1
	for i, name in ipairs(TAB_NAMES) do
		local seg = (i > 1 and " │ " or " ") .. (i == M.state.tab and name:upper() or name:lower())
		local hl = i == M.state.tab and "TuiterTabActive" or "TuiterTabInactive"
		vim.api.nvim_buf_add_highlight(buf, -1, hl, 0, pos, pos + #seg)
		pos = pos + #seg
	end
	-- highlight status badge
	if badge ~= "" then
		local bpos = line:find(badge, 1, true)
		if bpos then
			local code = tonumber(badge:match("%d+"))
			local hl = code and status_badge_hl(code) or "TuiterStatusErr"
			vim.api.nvim_buf_add_highlight(buf, -1, hl, 0, bpos - 1, bpos - 1 + #badge)
		end
	end
end

--- Rows for the Insomnia-style "Timeline" tab (from curl timing data).
function M.timeline_lines(resp)
	local lines, w = {}, 22
	if resp.error and resp.error ~= "" and resp.status == 0 then
		lines[#lines + 1] = "✗ " .. resp.error
		lines[#lines + 1] = ""
	end
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

-- Split-mode helpers: tab bar as first line in the same buffer as the body

local function render_tab_line(resp, spec)
	local reason = resp.headers:match("^HTTP/%S+ %d+ ([^\r\n]*)") or ""
	local ok = resp.ok and resp.status < 400
	-- method dot (colored circle before method name)
	local method = (spec and spec.method) or ""
	local method_dot = method ~= "" and ("● ") or ""
	-- tab names with solid separators
	local tab_part = ""
	for i, name in ipairs(TAB_NAMES) do
		if i > 1 then
			tab_part = tab_part .. " │ "
		end
		tab_part = tab_part .. (i == M.state.tab and name:upper() or name:lower())
	end
	-- status badge
	local badge = ""
	if resp.status > 0 then
		badge = fmt_status_badge(resp.status)
	elseif resp.error and resp.error ~= "" then
		badge = " ERR "
	end
	-- timing
	local timing = string.format("%dms", (resp.time or 0) * 1000)
	local size = fmt_size(resp.size)
	local line = " " .. method_dot .. method .. "  " .. tab_part
	local win = M.state.resp_split_win
	local width = win and vim.api.nvim_win_get_width(win) or 80
	-- right-align: badge + timing + size
	local right = badge .. " " .. timing .. " · " .. size
	if #line + #right + 3 < width then
		line = line .. string.rep(" ", width - #line - #right) .. right
	end
	return line, ok, badge, method
end

local function highlight_tab_line(buf, line, resp, method, badge)
	-- highlight method dot + name
	if method and method ~= "" then
		local dot_pos = line:find("●", 1, true)
		if dot_pos then
			vim.api.nvim_buf_add_highlight(buf, -1, METHOD_HL[method] or "Comment", 0, dot_pos - 1, dot_pos + 1)
		end
		local method_end = line:find(method, dot_pos and dot_pos or 1, true)
		if method_end then
			vim.api.nvim_buf_add_highlight(buf, -1, METHOD_HL[method] or "Comment", 0, method_end - 1, method_end - 1 + #method)
		end
	end
	-- highlight tab names (active = bold, inactive = dim)
	local pos = 1
	for i, name in ipairs(TAB_NAMES) do
		local seg = (i > 1 and " │ " or " ") .. (i == M.state.tab and name:upper() or name:lower())
		local hl = i == M.state.tab and "TuiterTabActive" or "TuiterTabInactive"
		vim.api.nvim_buf_add_highlight(buf, -1, hl, 0, pos, pos + #seg)
		pos = pos + #seg
	end
	-- highlight status badge
	if badge and badge ~= "" then
		local bpos = line:find(badge, 1, true)
		if bpos then
			local code = tonumber(badge:match("%d+"))
			local hl = code and status_badge_hl(code) or "TuiterStatusErr"
			vim.api.nvim_buf_add_highlight(buf, -1, hl, 0, bpos - 1, bpos - 1 + #badge)
		end
	end
end

--- Render response content into the split buffer (below the tab bar line).
local function render_split_content()
	local buf = M.state.resp_split_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) or not M.state.last then
		return
	end
	local resp = M.state.last.resp
	vim.bo[buf].modifiable = true
	-- read existing tab line (line 1)
	local tab_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
	local new_tab_line, ok, badge, method = render_tab_line(resp, M.state.last and M.state.last.spec)
	if new_tab_line ~= tab_line then
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, { new_tab_line })
		highlight_tab_line(buf, new_tab_line, resp, method, badge)
	end
	-- build the content lines for the current tab
	local content_lines = {}
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
		content_lines = vim.split(content, "\n")
		-- P3: truncate >200KB, show [show-all] toggle
		local raw_size = #resp.body or 0
		if raw_size > 200 * 1024 then
			local max_lines = 2000
			if #content_lines > max_lines then
				local truncated = vim.list_extend({}, content_lines, 1, max_lines)
				truncated[#truncated + 1] = ""
				truncated[#truncated + 1] = string.format(
					"[show-all] truncated %d lines (%.1fKB) — press gt to view raw",
					#content_lines - max_lines,
					raw_size / 1024
				)
				content_lines = truncated
			end
		end
	elseif M.state.tab == 2 then
		content_lines = resp.headers ~= "" and vim.split(resp.headers, "\n") or { "(no headers)" }
	elseif M.state.tab == 3 then
		content_lines = M.timeline_lines(resp)
	else
		-- Tests tab
		local tests = resp.tests or {}
		if #tests == 0 then
			content_lines = { "(no # @test assertions)" }
		else
			for _, te in ipairs(tests) do
				local icon = te.pass and "✓" or "✗"
				local l = icon .. " " .. (te.expr or "")
				if te.actual ~= nil then
					l = l .. "   · got: " .. trunc(fmt_actual(te.actual), 60)
				elseif te.error then
					l = l .. "   · " .. te.error
				end
				content_lines[#content_lines + 1] = l
			end
		end
	end
	-- replace lines 3+ (line 1 = tab, line 2 = blank separator)
	local new_lines = { new_tab_line, "" }
	for _, l in ipairs(content_lines) do
		new_lines[#new_lines + 1] = l
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
	highlight_tab_line(buf, new_tab_line, resp, method, badge)
	-- filetype + treesitter for body tab
	if M.state.tab == 1 then
		local ft = M.state.display and M.state.display.json and "json" or body_filetype(resp)
		if ft then
			vim.bo[buf].filetype = ft
			pcall(vim.treesitter.start, buf, ft)
		end
		if M.state.display and M.state.display.json then
			vim.wo[M.state.resp_split_win].foldmethod = "expr"
			vim.wo[M.state.resp_split_win].foldexpr = "v:lua.vim.treesitter.foldexpr()"
			vim.wo[M.state.resp_split_win].foldlevel = 99
		else
			vim.wo[M.state.resp_split_win].foldmethod = "manual"
		end
	elseif M.state.tab == 2 then
		vim.bo[buf].filetype = "text"
		for i, hl in ipairs(content_lines) do
			local key = hl:match("^([^:]+):")
			if key then
				vim.api.nvim_buf_add_highlight(buf, -1, "TuiterHeaderKey", i + 1, 0, #key)
			end
		end
	elseif M.state.tab == 3 then
		vim.bo[buf].filetype = "text"
		for i, tl in ipairs(content_lines) do
			vim.api.nvim_buf_add_highlight(buf, -1, "Comment", i + 1, 22, -1)
		end
	else
		vim.bo[buf].filetype = "text"
		local tests = resp.tests or {}
		for i, te in ipairs(tests) do
			vim.api.nvim_buf_add_highlight(buf, -1, te.pass and "TuiterOk" or "TuiterError", i + 1, 0, -1)
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
	local method_hl = METHOD_HL[spec.method] or "Comment"
	-- encoding
	local encoding = resp.headers:lower():match("content%-encoding:%s*(%S+)") or ""
	local enc_part = encoding ~= "" and (" · " .. encoding) or ""
	-- content-type short form
	local ct = content_type(resp)
	local ct_short = ct:match("([^/]+)$") or ct
	local ct_part = ct ~= "" and (" · " .. ct_short) or ""
	-- env
	local env = spec.env and (" · " .. spec.env) or ""
	-- status badge
	local badge = ""
	if resp.status > 0 then
		badge = fmt_status_badge(resp.status)
	elseif resp.error and resp.error ~= "" then
		badge = " ERR "
	end
	-- timing + size
	local timing = string.format("%dms", (resp.time or 0) * 1000)
	local size = fmt_size(resp.size)
	-- key hints (compact)
	local hints = "q quit │ 1-4 tabs │ p pretty │ y copy │ r retry │ D diff"
	vim.wo[win].statusline = table.concat({
		"%#TuiterStatusHint#",
		" ",
		spec.method,
		" %*",
		"%#TuiterUrl#",
		trunc(spec.url, 35),
		" %*",
		"%#" .. (ok and "TuiterStatusOk" or "TuiterStatusErr") .. "#",
		badge,
		" %*",
		timing .. " · " .. size .. enc_part .. ct_part .. env,
		" │ ",
		"%#TuiterFooterKey#",
		hints,
		"%*",
	}, "")
end

--- Show a response. opts: { resend = fn, copy_curl = fn }
function M.show(resp, spec, opts)
	opts = opts or {}
	M.close_spinner() -- dismiss loading spinner
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

	if layout_mode() == "split" then
		-- split mode: botright vsplit for response, tab bar as first line
		local body_buf = mk_buf()
		vim.cmd("botright vsplit")
		local body_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(body_win, body_buf)
		vim.wo[body_win].wrap = true
		vim.wo[body_win].number = true
		vim.wo[body_win].winfixwidth = true
		local resp_width = (opts.windows and opts.windows.width) or 120
		pcall(vim.api.nvim_win_set_width, body_win, math.min(resp_width, vim.o.columns - 4))
		-- tab bar as first line in the same buffer
		vim.bo[body_buf].modifiable = true
		local tab_line, _, badge = render_tab_line(resp, spec)
		vim.api.nvim_buf_set_lines(body_buf, 0, 0, false, { tab_line, "" })
		highlight_tab_line(body_buf, tab_line, resp, spec.method, badge)
		vim.bo[body_buf].modifiable = false
		set_statusline(body_win, resp, spec)
		M.state.resp_split_win, M.state.resp_split_buf = body_win, body_buf

		-- keymaps on the response split
		buf_map(body_buf, "q", function()
			M.close_response()
		end, "Close response")
		buf_map(body_buf, "t", M.cycle_tab, "Next tab")
		buf_map(body_buf, "1", function()
			M.set_tab(1)
		end, "Body tab")
		buf_map(body_buf, "2", function()
			M.set_tab(2)
		end, "Headers tab")
		buf_map(body_buf, "3", function()
			M.set_tab(3)
		end, "Timeline tab")
		buf_map(body_buf, "4", function()
			M.set_tab(4)
		end, "Tests tab")
		buf_map(body_buf, "p", M.toggle_pretty, "Toggle pretty/raw body")
		buf_map(body_buf, "y", M.yank_body, "Copy current tab")
		buf_map(body_buf, "f", M.save_body, "Save body to file")
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
		buf_map(body_buf, "P", M.copy_json_path, "Copy JSON path")
		buf_map(body_buf, "V", M.copy_json_value, "Copy JSON value")
		buf_map(body_buf, "U", M.copy_url, "Copy resolved URL")
		buf_map(body_buf, "gx", function()
			local last = M.state.last
			if last then
				vim.ui.open(client.resolve_url(last.spec))
			end
		end, "Open request URL in browser")

		render_split_content()
	else
		-- float mode (default)
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
		buf_map(body_buf, "P", M.copy_json_path, "Copy JSON path")
		buf_map(body_buf, "V", M.copy_json_value, "Copy JSON value")
		buf_map(body_buf, "U", M.copy_url, "Copy resolved URL")
		buf_map(body_buf, "gx", function()
			local last = M.state.last
			if last then
				vim.ui.open(client.resolve_url(last.spec))
			end
		end, "Open request URL in browser")

		vim.wo[body_win].wrap = true
		vim.wo[body_win].number = true -- Postman-style line numbers on the response
		set_statusline(body_win, resp, spec)
		M.state.head_win, M.state.body_win = head_win, body_win
		render_tabs()
		render_content()
	end
end

--- Switch the response tab (1=Body, 2=Headers, 3=Timeline, 4=Tests).
function M.set_tab(n)
	if not M.state.last then
		return
	end
	M.state.tab = n
	if is_valid(M.state.resp_split_win) then
		-- split mode: tab bar is line 1, content starts at line 3
		render_split_content()
		pcall(vim.api.nvim_set_current_win, M.state.resp_split_win)
	else
		-- float mode
		render_tabs()
		render_content()
		if is_valid(M.state.body_win) then
			vim.api.nvim_set_current_win(M.state.body_win)
		end
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
	local is_split = is_valid(M.state.resp_split_win)
	if not is_split and not is_valid(M.state.body_win) then
		return
	end
	if not M.state.display then
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
	if is_split then
		render_split_content()
	else
		render_content()
	end
end

function M.yank_body()
	local is_split = is_valid(M.state.resp_split_win)
	if not is_split and not is_valid(M.state.body_win) then
		return
	end
	local buf = is_split and M.state.resp_split_buf or vim.api.nvim_win_get_buf(M.state.body_win)
	local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local start = is_split and 3 or 1 -- skip tab bar line in split mode
	local text = table.concat(vim.list_extend({}, all_lines, start, #all_lines), "\n")
	vim.fn.setreg('"', text)
	vim.notify("Tuiter: " .. TAB_NAMES[M.state.tab]:lower() .. " copied", vim.log.levels.INFO, { title = "Tuiter" })
end

--- JSON body tab helpers for `P` / `V`.
local function body_lines()
	if
		not is_valid(M.state.body_win)
		or M.state.tab ~= 1
		or not M.state.pretty
		or not M.state.display
		or not M.state.display.json
	then
		return nil
	end
	return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(M.state.body_win), 0, -1, false)
end

--- Extract the value at the cursor: scalar value, or the pretty-printed
--- subtree when the node is a container ({"key": {…}} / bare { [).
local function body_value()
	local lines = body_lines()
	if not lines then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(M.state.body_win)[1]
	local l = lines[line] or ""
	local is_container = l == "{" or l == "[" or l:match('%": %[%{%[]%s*$') ~= nil
	if is_container then
		local indent = #(l:match("^( *)"))
		local out = { l }
		for i = line + 1, #lines do
			out[#out + 1] = lines[i]
			local close = lines[i]:match("^%s*([%]}])%s*$")
			if close and #(lines[i]:match("^( *)")) <= indent then
				break
			end
		end
		return table.concat(out, "\n")
	end
	local v = l:match('^ *"[^%"]+":%s*(.-)%s*$')
	if v == nil then
		v = l:match("^%s*(.-)%s*$")
	end
	v = v:gsub(",%s*$", "") -- pretty render trails commas on non-final array items
	if v:sub(1, 1) == '"' and v:sub(-1) == '"' then
		v = v:sub(2, -2):gsub('\\"', '"')
	end
	return v
end

--- `P`: copy the JSONPath of the node under the cursor ($.users[0].name).
function M.copy_json_path()
	local lines = body_lines()
	if not lines then
		return
	end
	local line = vim.api.nvim_win_get_cursor(M.state.body_win)[1]
	local path = M.json_path(lines, line)
	vim.fn.setreg('"', path)
	vim.notify("Tuiter: copied " .. path, vim.log.levels.INFO, { title = "Tuiter" })
end

--- `V`: copy the JSON value at the cursor (scalar, or the pretty subtree).
function M.copy_json_value()
	local v = body_value()
	if v == nil or v == "" then
		vim.notify("Tuiter: nothing to copy here", vim.log.levels.INFO, { title = "Tuiter" })
		return
	end
	vim.fn.setreg('"', v)
	vim.notify("Tuiter: copied value", vim.log.levels.INFO, { title = "Tuiter" })
end

--- `U`: copy the resolved request URL (method + URL, vars substituted).
function M.copy_url()
	local last = M.state.last
	if not last then
		return
	end
	local url = client.resolve_url(last.spec)
	vim.fn.setreg('"', last.spec.method .. " " .. url)
	vim.notify("Tuiter: copied " .. last.spec.method .. " " .. url, vim.log.levels.INFO, { title = "Tuiter" })
end

function M.save_body()
	local is_split = is_valid(M.state.resp_split_win)
	if not is_split and not is_valid(M.state.body_win) then
		return
	end
	local buf = is_split and M.state.resp_split_buf or vim.api.nvim_win_get_buf(M.state.body_win)
	local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local start = is_split and 3 or 1 -- skip tab bar in split mode
	local text = table.concat(vim.list_extend({}, all_lines, start, #all_lines), "\n")
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
	-- show loading spinner in response area
	M.show_spinner(spec)
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
	M.state.resp_detail[spec.url] = { time = resp.time, size = resp.size, error = resp.error }
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

--- Show every {{var}} used by a request with its resolved value and source
--- (request / env / os / dynamic / response). `<leader>iv` / :TuiterVars.
function M.vars_float(spec)
	local names = {}
	local function collect(str)
		if type(str) ~= "string" then
			return
		end
		for name in str:gmatch("{{" .. "([%w_$%.]+)" .. "}}") do
			names[name] = true
		end
	end
	collect(spec.url)
	collect(spec.opts and spec.opts.base or "") -- # @base may itself contain {{vars}}
	for _, h in ipairs(spec.headers or {}) do
		collect(h)
	end
	collect(spec.body)
	for k, v in pairs(spec.vars or {}) do
		names[k] = true
		if type(v) == "table" then
			for _, vv in ipairs(v) do
				collect(tostring(vv))
			end
		else
			collect(tostring(v))
		end
	end
	local sorted = vim.tbl_keys(names)
	table.sort(sorted)
	local lines = {}
	for _, name in ipairs(sorted) do
		local value, source = client.resolve_name(name, spec.vars)
		if value == nil then
			lines[#lines + 1] = "{{" .. name .. "}} → ⚠ unresolved"
		else
			lines[#lines + 1] = ("{{" .. name .. "}} → %s (%s)"):format(value:gsub("[\r\n]+", "⏎"), source)
		end
	end
	open_aux(string.format("resolved vars — %s %s", spec.method, trunc(client.resolve_url(spec), 40)), lines)
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

--- Parse a line of the pretty JSON render into its path fragment.
local function path_part(key)
	if key:match("^[%w_]+$") then
		return "." .. key
	end
	return '["' .. key .. '"]'
end

--- Compute the JSONPath ($.users[0].name) of the node on `lineno` of a
--- tuiter-pretty-printed JSON body (2-space indent, sorted keys, array items
--- rendered bare). Pure function — unit-tested.
function M.json_path(lines, lineno)
	local stack = {} -- { indent = n, part = string }
	local counts = {} -- indent -> array elements rendered at that indent so far
	local path = "$"
	local function set_path()
		path = "$"
		for _, e in ipairs(stack) do
			path = path .. e.part
		end
	end
	local function pop_from(indent, ge)
		while #stack > 0 and (ge and stack[#stack].indent >= indent or stack[#stack].indent > indent) do
			table.remove(stack)
		end
	end
	for i = 1, math.min(lineno, #lines) do
		local line = lines[i]
		local indent = #(line:match("^( *)"))
		if line:match("^%s*[%]}][,%s]*$") then
			-- container close (may carry a trailing comma in the pretty render)
			pop_from(indent, true)
			for k in pairs(counts) do
				if k > indent then
					counts[k] = nil
				end
			end
			set_path()
		else
			local sp, key = line:match('^( *)"([^%"]+)":')
			if key then
				pop_from(indent, true)
				stack[#stack + 1] = { indent = indent, part = path_part(key) }
				set_path()
			elseif line:match("^%s*[%{%[]%s*$") then
				-- bare container open: root, or an array element rendered as { / [
				if line:match("^%s*%[") and #stack == 0 then
					-- root array: sentinel so its items get [n] parts
					stack[#stack + 1] = { indent = 0, part = "" }
				elseif #stack > 0 then
					pop_from(indent, false)
					local idx = counts[indent] or 0
					counts[indent] = idx + 1
					stack[#stack + 1] = { indent = indent, part = "[" .. idx .. "]" }
				end
				set_path()
			elseif #stack > 0 then
				-- scalar array element (e.g. `    1,`, `    "s"`, `    true`)
				pop_from(indent, true)
				local idx = counts[indent] or 0
				counts[indent] = idx + 1
				local el = "[" .. idx .. "]"
				set_path()
				path = path .. el
			end
		end
	end
	return path
end

--- Jump to the next/previous top-level JSON key in the pretty body tab.
function M.jump_key(dir)
	local is_split = is_valid(M.state.resp_split_win)
	local body_win = is_split and M.state.resp_split_win or M.state.body_win
	if not is_valid(body_win) or M.state.tab ~= 1 or not M.state.display or not M.state.display.json then
		return
	end
	local buf = is_split and M.state.resp_split_buf or vim.api.nvim_win_get_buf(body_win)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local content_start = is_split and 3 or 1 -- skip tab bar in split mode
	local keys = {}
	for i = content_start, #lines do
		local line = lines[i]
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
	if is_valid(M.state.body_win) or is_valid(M.state.head_win) or is_valid(M.state.resp_split_win) then
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

	-- Nerd-Font icon detection: prefer Nerd glyphs when a Nerd Font is active
	local has_nerd = vim.g.nerdfont == true
			or (vim.o.guifont and vim.o.guifont:lower():find("nerd"))
		or false
	local icon_check = has_nerd and "" or "✓"
	local icon_cross = has_nerd and "" or "✗"
	local icon_star = has_nerd and "" or "★"
	local icon_star_off = has_nerd and "" or "☆"

	local buf = mk_buf()
	local lines = {}
	local fav_count = 0
	local nonfav_count = 0
	for _, r in ipairs(entries) do
		if M.state.favs[r.url] then
			fav_count = fav_count + 1
		else
			nonfav_count = nonfav_count + 1
		end
	end
	local in_favs = true
	for _, r in ipairs(entries) do
		-- separator between favorites and non-favorites
		if in_favs and not M.state.favs[r.url] and nonfav_count > 0 and fav_count > 0 then
			lines[#lines + 1] = string.rep("─", 56)
			vim.api.nvim_buf_add_highlight(buf, -1, "TuiterSep", #lines - 1, 0, -1)
			in_favs = false
		end
		local st = M.state.results[r.url]
		local det = M.state.resp_detail[r.url]
		local mark
		if st then
			if st > 0 then
				mark = string.format("%s %d %dms", icon_check, st, math.floor((det and det.time or 0) * 1000))
			elseif det and det.error and det.error ~= "" then
				mark = icon_cross .. " " .. trunc(det.error, 9)
			else
				mark = icon_cross
			end
		else
			mark = "  "
		end
		local star = M.state.favs[r.url] and icon_star or " "
		local label = r.name ~= "" and r.name or r.url
		local url = r.name ~= "" and r.url or ""
		lines[#lines + 1] = string.format("%s %-14s %-6s %-24s %s", star, mark, r.method, trunc(label, 24), trunc(url, 20))
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	-- highlight entries (track buf line separately from entry index due to separator)
	local buf_line = 0
	local sep_inserted = false
	for i, r in ipairs(entries) do
		-- skip separator line if present
		if i > 1 and M.state.favs[entries[i - 1].url] and not M.state.favs[r.url] and fav_count > 0 and nonfav_count > 0 and not sep_inserted then
			buf_line = buf_line + 1
			sep_inserted = true
		end
		if M.state.favs[r.url] then
			vim.api.nvim_buf_add_highlight(buf, -1, "TuiterStar", buf_line, 0, 1)
		end
		local status = M.state.results[r.url]
		if status then
			vim.api.nvim_buf_add_highlight(buf, -1, status < 400 and "TuiterOk" or "TuiterError", buf_line, 2, 16)
		end
		vim.api.nvim_buf_add_highlight(buf, -1, METHOD_HL[r.method] or "Comment", buf_line, 17, 17 + #r.method)
		buf_line = buf_line + 1
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

	local win
	if layout_mode() == "split" then
		-- split mode: topleft vsplit with winfixwidth
		local sw = (opts.windows and opts.windows.sidebar_width) or 62
		vim.cmd("topleft " .. sw .. "vsplit")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.wo[win].winfixwidth = true
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
		vim.wo[win].cursorline = true
		-- window title + key hints via statusline
		local hint = "↵ run │ ★ fav │ / filter │ e env │ a all │ ? help"
		vim.wo[win].statusline = "%#TuiterStatusHint# " .. title .. " %*│ %#TuiterFooterKey#" .. hint .. "%*"
	else
		-- float mode (default)
		win = vim.api.nvim_open_win(buf, true, {
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
	end

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
