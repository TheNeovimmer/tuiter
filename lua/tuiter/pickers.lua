--- Telescope extension for tuiter: pick history entries, buffer requests,
--- or environments. Load lazily via `:Telescope tuiter history` and friends.
--- Register it in your telescope config:
---
---   require("telescope").load_extension("tuiter")
local pickers = nil
local finders = nil
local conf = nil
local actions = nil

local function lazy()
	if pickers then
		return
	end
	pickers = require("telescope.pickers")
	finders = require("telescope.finders")
	conf = require("telescope.config").values
	actions = require("telescope.actions")
end

local function make(entries, opts)
	lazy()
	pickers
		.new({}, {
			prompt_title = opts.title,
			finder = finders.new_table({
				results = entries,
				entry_maker = opts.entry,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				if opts.select then
					actions.select_default:replace(function()
						local sel = actions.get_selected_entry(prompt_bufnr).value
						actions.close(prompt_bufnr)
						opts.select(sel)
					end)
				end
				return true
			end,
		})
		:find()
end

local M = {
	--- `:Telescope tuiter history` — replay a past request.
	history = function()
		local history = require("tuiter.history")
		local entries = history.load()
		make(entries, {
			title = "tuiter history",
			entry = function(e)
				return {
					value = e,
					display = string.format("%-12s %-6s %s", os.date("%m-%d %H:%M", e.ts), e.method, e.url),
					ordinal = e.url .. " " .. e.method,
				}
			end,
			select = function(e)
				require("tuiter").resend(e.spec)
			end,
		})
	end,

	--- `:Telescope tuiter requests` — pick & run a request in the current buffer.
	requests = function()
		local parser = require("tuiter.parser")
		local reqs = parser.parse_lines(vim.api.nvim_buf_get_lines(0, 0, -1, false))
		make(reqs, {
			title = "tuiter requests",
			entry = function(r)
				return {
					value = r,
					display = string.format("%-6s %s", r.method, r.name ~= "" and (r.name .. " — " .. r.url) or r.url),
					ordinal = r.name .. " " .. r.url .. " " .. r.method,
				}
			end,
			select = function(r)
				require("tuiter").resend(r)
			end,
		})
	end,

	--- `:Telescope tuiter env` — switch environment.
	env = function()
		local client = require("tuiter.client")
		local cwd = vim.fn.getcwd()
		local envs = client.envs(cwd, require("tuiter").opts())
		make(envs, {
			title = "tuiter environments",
			entry = function(n)
				return { value = n, display = n, ordinal = n }
			end,
			select = function(n)
				require("tuiter.client").set_env(n, cwd, require("tuiter").opts())
				vim.notify(string.format("Tuiter: environment set to %q", n), vim.log.levels.INFO, { title = "Tuiter" })
			end,
		})
	end,
}

return M
