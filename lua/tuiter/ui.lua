--- Response UI: floating windows for responses + a Postman-style request
--- sidebar listing every request in the current file.
local client = require("tuiter.client")

local M = {
	state = {
		head_win = nil,
		body_win = nil,
		last = nil, -- { resp, spec, opts } of the last shown response
		pretty = true, -- pretty vs raw JSON body
		display = nil, -- { raw, pretty, json } of the shown body
		results = {}, -- url -> http status, shown as marks in the sidebar
		sidebar_win = nil,
		sidebar_buf = nil,
	},
}

vim.api.nvim_set_hl(0, "TuiterOk", { link = "DiagnosticOk" })
vim.api.nvim_set_hl(0, "TuiterError", { link = "DiagnosticError" })
vim.api.nvim_set_hl(0, "TuiterGet", { link = "DiagnosticOk" })
vim.api.nvim_set_hl(0, "TuiterPost", { link = "DiagnosticInfo" })
vim.api.nvim_set_hl(0, "TuiterPut", { link = "DiagnosticWarn" })
vim.api.nvim_set_hl(0, "TuiterPatch", { link = "DiagnosticWarn" })
vim.api.nvim_set_hl(0, "TuiterDelete", { link = "DiagnosticError" })

local METHOD_HL = {
	GET = "TuiterGet",
	POST = "TuiterPost",
	PUT = "TuiterPut",
	PATCH = "TuiterPatch",
	DELETE = "TuiterDelete",
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

local function open_floats(head_buf, head_lines, body_buf, head_title, body_title)
	local cols, rows = vim.o.columns, vim.o.lines
	local width = math.min(120, cols - 8)
	local col = math.floor((cols - width) / 2)
	local head_h = math.min(#head_lines + 2, 12)
	local body_h = math.max(5, math.min(40, rows - head_h - 12))

	local head_win = vim.api.nvim_open_win(head_buf, false, {
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
	local body_win = vim.api.nvim_open_win(body_buf, true, {
		relative = "editor",
		width = width,
		height = body_h,
		row = 3 + head_h,
		col = col,
		border = "rounded",
		style = "minimal",
		title = " " .. body_title .. " ",
		title_pos = "center",
	})
	return head_win, body_win
end

--- Show a response. opts: { resend = fn, copy_curl = fn }
function M.show(resp, spec, opts)
	opts = opts or {}
	M.state.last = { resp = resp, spec = spec, opts = opts }
	M.state.results[spec.url] = resp.status
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
		open_floats(head_buf, hlines, body_buf, status_line, string.format("%s %s %s", spec.method, spec.url, env))

	buf_map(head_buf, "q", M.close, "Close response")
	buf_map(head_buf, "t", M.toggle_headers, "Toggle headers")
	buf_map(body_buf, "q", M.close, "Close response")
	buf_map(body_buf, "t", M.toggle_headers, "Toggle headers")
	buf_map(body_buf, "p", M.toggle_pretty, "Toggle pretty/raw body")
	buf_map(body_buf, "y", M.yank_body, "Copy body")
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
end

--- Show the request list. opts: { title, env, run = fn(spec), go_to = fn(lnum) }
function M.show_sidebar(requests, opts)
	M.close_sidebar()
	if #requests == 0 then
		return
	end
	local buf = mk_buf()
	local lines = {}
	local hl = {}
	for i, r in ipairs(requests) do
		local mark = M.state.results[r.url] and string.format("[%d]", M.state.results[r.url]) or "    "
		local label = r.name ~= "" and r.name or r.url
		local url = r.name ~= "" and r.url or ""
		lines[#lines + 1] = string.format("%s %-6s %-24s %s", mark, r.method, trunc(label, 24), trunc(url, 20))
		hl[#hl + 1] = METHOD_HL[r.method] or "Comment"
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	for i, group in ipairs(hl) do
		vim.api.nvim_buf_add_highlight(buf, -1, group, i - 1, 5, 5 + #requests[i].method)
	end
	vim.bo[buf].modifiable = false

	local title = opts.title and (" — " .. opts.title) or ""
	if opts.env then
		title = title .. " (env: " .. opts.env .. ")"
	end
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = 58,
		height = math.min(#lines + 2, vim.o.lines - 4),
		row = 2,
		col = 2,
		border = "rounded",
		style = "minimal",
		title = " requests" .. title .. " ",
		title_pos = "center",
	})

	buf_map(buf, "q", M.close_sidebar, "Close request list")
	buf_map(buf, "<CR>", function()
		local spec = requests[vim.api.nvim_win_get_cursor(0)[1]]
		if spec then
			M.close_sidebar()
			if opts.run then
				opts.run(spec)
			end
		end
	end, "Run request")
	buf_map(buf, "g", function()
		local spec = requests[vim.api.nvim_win_get_cursor(0)[1]]
		if spec and opts.go_to then
			opts.go_to(spec.line)
		end
	end, "Go to request in file")

	M.state.sidebar_win, M.state.sidebar_buf = win, buf
end

return M
