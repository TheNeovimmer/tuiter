--- tuiter: interactive API explorer for Neovim.
--- Public API + wiring: config, run/resend, history, env, response toggle.
local parser = require("tuiter.parser")
local client = require("tuiter.client")
local ui = require("tuiter.ui")
local history = require("tuiter.history")

local M = {}

local config = {
	keymaps = {
		run = "<leader>ht", -- send request under cursor
		history = "<leader>hh",
		env = "<leader>he",
		toggle = "<leader>hc",
	},
	curl = { timeout = 30, insecure = false, max_redirects = 8 },
	env_files = { "http-client.env.json", "tuiter.env.json" },
	default_env = "default",
}

---@param opts? table
function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})
end

--- Send a request spec directly (no buffer parsing). Async; shows the
--- response window and records history when done.
---@param spec table {method, url, headers?, body?, vars?, name?, cwd?}
function M.resend(spec)
	local cwd = spec.cwd or vim.fn.getcwd()
	client.ensure_env(cwd, config)
	vim.notify(string.format("Tuiter: %s %s", spec.method, spec.url), vim.log.levels.INFO, { title = "Tuiter" })
	client.send(spec, config.curl, cwd, function(resp)
		vim.schedule(function()
			ui.show(resp, spec, function()
				M.resend(spec)
			end)
			history.add(spec, resp)
		end)
	end)
end

--- Send the request under the cursor (or at opts.lnum) of buffer opts.buf.
---@param opts? {buf?: integer, lnum?: integer}
function M.run(opts)
	opts = opts or {}
	local buf = opts.buf or 0
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local lnum = opts.lnum or vim.api.nvim_win_get_cursor(0)[1]
	local spec = parser.at(parser.parse_lines(lines), lnum)
	if not spec then
		vim.notify("Tuiter: no request found under cursor", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end
	spec.buf = buf
	spec.cwd = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p:h")
	M.resend(spec)
end

--- Pick a past request from history and re-run it.
function M.history()
	history.pick(function(spec)
		M.resend(spec)
	end)
end

---@param opts? {cwd?: string}
function M.select_env(opts)
	local cwd = (opts and opts.cwd) or vim.fn.getcwd()
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
		end
	end)
end

function M.toggle_response()
	ui.toggle()
end

function M.close_response()
	ui.close()
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
	if km.history then
		map(km.history, M.history, "Request history")
	end
	if km.env then
		map(km.env, function()
			M.select_env({ cwd = dir })
		end, "Select environment")
	end
	if km.toggle then
		map(km.toggle, M.toggle_response, "Toggle response")
	end
end

return M
