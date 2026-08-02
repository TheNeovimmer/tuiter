-- LazyVim smoke test: load the REAL user config, then verify tuiter's
-- lazy-loading, ftplugin keymaps, diagnostics, sidebar, and a real send.
-- Usage: nvim --headless -u <real-init> -c 'luafile tests/lazyvim_smoke.lua'
local function finish(code)
	vim.cmd("cquit" .. (code == 0 and "" or " " .. code))
end

local function run_checks()
	local failed = 0
	local function eq(got, want, label)
		if got ~= want then
			failed = failed + 1
			print(("SMOKE FAIL %s: got %q, want %q"):format(label, tostring(got), tostring(want)))
		end
	end

	local f = "examples/demo.http"
	vim.cmd("edit " .. f)
	vim.wait(2000, function() end) -- lazy.nvim ft-loads tuiter
	local hbuf = vim.api.nvim_get_current_buf()
	eq(vim.bo[0].filetype, "http", "filetype http after edit")
	local maps = 0
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
		if m.desc and m.desc:match("^Tuiter") then
			maps = maps + 1
		end
	end
	eq(maps >= 8, true, "ftplugin keymaps via real FileType autocmd: " .. maps)
	vim.cmd("Tuiter")
	vim.wait(1000, function() end)
	local ui = require("tuiter.ui")
	eq(ui.sidebar_is_open(), true, "Tuiter sidebar opens")
	vim.cmd("q")
	vim.wait(500, function() end)
	-- send the first request (jsonplaceholder is public; any HTTP response counts)
	vim.api.nvim_win_set_cursor(0, { 2, 0 })
	vim.cmd("TuiterRun")
	local got = vim.wait(20000, function()
		local r = require("tuiter.client").state.response
		return r and r.status and r.status > 0
	end)
	eq(got, true, "TuiterRun completed a request")
	-- diagnostics: break a line, write, expect a warning
	vim.api.nvim_set_current_buf(hbuf)
	vim.api.nvim_buf_set_lines(hbuf, 0, 1, false, { "GET", "### x" })
	vim.api.nvim_buf_call(hbuf, function()
		vim.cmd("write")
	end)
	vim.wait(500, function() end)
	eq(#vim.diagnostic.get(hbuf) >= 1, true, "diagnostics fire on malformed line")

	print(failed == 0 and "ALL LAZYVIM SMOKE TESTS PASSED" or (failed .. " SMOKE FAILURES"))
	finish(failed == 0 and 0 or 1)
end

-- wait for lazy.nvim's :Lazy command, then trigger ft-load and check
local deadline = vim.loop.hrtime() + 90e9
local function wait_for_lazy()
	if vim.fn.exists(":Lazy") == 2 then
		run_checks()
		return
	end
	if vim.loop.hrtime() > deadline then
		print("SMOKE FAIL lazy.nvim did not load :Lazy")
		finish(1)
		return
	end
	vim.defer_fn(wait_for_lazy, 500)
end
wait_for_lazy()
