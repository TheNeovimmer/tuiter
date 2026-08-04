-- .http filetype plugin
vim.bo.commentstring = "# %s"
vim.bo.omnifunc = "v:lua.require('tuiter').complete"
require("tuiter").setup_keymaps(0)

-- Resolution of {{var}} under the cursor: `K` hover + `gd` definition-jump.
local function var_under_cursor()
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2]
	local i = 1
	while i <= #line do
		local s = line:find("{{", i, true)
		if not s then
			break
		end
		local e = line:find("}}", s + 2, true)
		if not e then
			break
		end
		if col >= s - 1 and col <= e + 1 then
			return line:sub(s + 2, e - 1)
		end
		i = e + 2
	end
	return nil
end

vim.keymap.set("n", "K", function()
	local name = var_under_cursor()
	if not name then
		return
	end
	local resolved = require("tuiter.client").substitute("{{" .. name .. "}}", {})
	local lines
	if resolved == "{{" .. name .. "}}" then
		lines = { name, "", "(unresolved placeholder)" }
	else
		lines = { name, "", "= " .. tostring(resolved) }
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	local w = vim.api.nvim_open_win(buf, false, {
		relative = "cursor",
		width = math.max(20, #(lines[3] or "") + 4),
		height = #lines,
		row = 1,
		col = 0,
		style = "minimal",
		border = "rounded",
	})
	vim.keymap.set("n", "q", function()
		pcall(vim.api.nvim_win_close, w, true)
	end, { buffer = buf })
end, { buffer = 0, desc = "Tuiter: resolve {{var}} under cursor (preview)" })

vim.keymap.set("n", "gd", function()
	local name = var_under_cursor()
	if not name then
		return
	end
	local env_file = require("tuiter").env_file()
	if not env_file or vim.fn.filereadable(env_file) == 0 then
		vim.notify("Tuiter: no env file loaded for this project", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	vim.cmd("edit " .. vim.fn.fnameescape(env_file))
	local lnum = vim.fn.search('"' .. vim.fn.escape(name, "[]") .. '"\\s*:', "n")
	if lnum and lnum > 0 then
		vim.api.nvim_win_set_cursor(0, { lnum, 0 })
	end
end, { buffer = 0, desc = "Tuiter: jump to {{var}} definition in the env file" })

-- Insomnia-style composer highlighting: color-coded methods, blue URLs,
-- section names, and @vars — applied per window (matchadd is window-scoped).
local function setup_composer_highlights()
	if vim.w.tuiter_composer_hl then
		return
	end
	vim.w.tuiter_composer_hl = true
	for _, m in ipairs({
		{ "TuiterGet", "GET" },
		{ "TuiterPost", "POST" },
		{ "TuiterPut", "PUT" },
		{ "TuiterPatch", "PATCH" },
		{ "TuiterDelete", "DELETE" },
	}) do
		vim.fn.matchadd(m[1], "\\v^\\s*\\zs" .. m[2] .. "\\ze\\s", 10)
	end
	vim.fn.matchadd("TuiterUrl", [[\v^\s*(GET|POST|PUT|PATCH|DELETE)\s+\zs\S+\ze]], 10)
	vim.fn.matchadd("TuiterSection", [[\v^\s*###\s.*$]], 9)
	vim.fn.matchadd("TuiterVar", [[\v^\s*\zs\@[\w_]+\ze]], 9)
end

vim.api.nvim_create_autocmd("BufWinEnter", {
	buffer = 0,
	callback = setup_composer_highlights,
})
setup_composer_highlights()

-- Lightweight diagnostics: catches malformed requests (missing URL, bad
-- scheme, header/body mistakes) while you edit, via nvim's LSP-style UI.
local diag_ns = vim.api.nvim_create_namespace("tuiter")

local function refresh_diagnostics()
	local issues = require("tuiter.parser").validate(vim.api.nvim_buf_get_lines(0, 0, -1, false))
	local diags = {}
	for _, iss in ipairs(issues) do
		diags[#diags + 1] = {
			lnum = iss.lnum - 1,
			col = 0,
			end_lnum = iss.lnum - 1,
			end_col = 0,
			severity = vim.diagnostic.severity.WARN,
			message = iss.msg,
			source = "tuiter",
		}
	end
	vim.diagnostic.set(diag_ns, 0, diags)
end

vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost", "InsertLeave", "TextChanged" }, {
	buffer = 0,
	callback = refresh_diagnostics,
})
