-- .http filetype plugin
vim.bo.commentstring = "# %s"
vim.bo.omnifunc = "v:lua.require('tuiter').complete"
require("tuiter").setup_keymaps(0)

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
