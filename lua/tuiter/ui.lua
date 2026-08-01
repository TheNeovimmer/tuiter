--- Response UI: two stacked floating windows (headers on top, body below).
local client = require("tuiter.client")

local M = { state = { head_win = nil, body_win = nil, last = nil } }

vim.api.nvim_set_hl(0, "TuiterOk", { link = "DiagnosticOk" })
vim.api.nvim_set_hl(0, "TuiterError", { link = "DiagnosticError" })

local function is_valid(w)
	return w and vim.api.nvim_win_is_valid(w)
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

function M.close()
	for _, w in ipairs({ M.state.head_win, M.state.body_win }) do
		if is_valid(w) then
			pcall(vim.api.nvim_win_close, w, true)
		end
	end
	M.state.head_win, M.state.body_win = nil, nil
end

local function buf_map(buf, lhs, rhs, desc)
	vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, desc = "Tuiter: " .. desc })
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

function M.show(resp, spec, on_resend)
	M.state.last = { resp = resp, spec = spec, on_resend = on_resend }
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
	local body = resp.body
	if is_json(resp) then
		body = client.pretty_json(body) or body
	end
	if body == "" then
		body = "(empty body)"
	end
	vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, vim.split(body, "\n"))
	if is_json(resp) then
		vim.bo[body_buf].filetype = "json"
		pcall(vim.treesitter.start, body_buf, "json")
	end
	vim.bo[body_buf].modifiable = false

	local head_win, body_win = open_floats(head_buf, hlines, body_buf, status_line, spec.method .. " " .. spec.url)

	buf_map(head_buf, "q", M.close, "Close response")
	buf_map(head_buf, "t", M.toggle_headers, "Toggle headers")
	buf_map(body_buf, "q", M.close, "Close response")
	buf_map(body_buf, "t", M.toggle_headers, "Toggle headers")
	buf_map(body_buf, "r", function()
		if on_resend then
			on_resend()
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
		M.show(M.state.last.resp, M.state.last.spec, M.state.last.on_resend)
	end
end

function M.toggle()
	if is_valid(M.state.body_win) or is_valid(M.state.head_win) then
		M.close()
	elseif M.state.last then
		M.show(M.state.last.resp, M.state.last.spec, M.state.last.on_resend)
	else
		vim.notify("Tuiter: no response yet", vim.log.levels.INFO, { title = "Tuiter" })
	end
end

return M
