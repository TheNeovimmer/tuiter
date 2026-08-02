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
