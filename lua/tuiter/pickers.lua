--- Telescope pickers for tuiter: full Telescope UI for all interactions.
--- Load lazily via `:Telescope tuiter <picker>`.
--- Register in telescope config: require("telescope").load_extension("tuiter")
local pickers = nil
local finders = nil
local conf = nil
local actions = nil
local action_state = nil
local make_entry = nil
local entry_display = nil

local function lazy()
	if pickers then
		return
	end
	pickers = require("telescope.pickers")
	finders = require("telescope.finders")
	conf = require("telescope.config").values
	actions = require("telescope.actions")
	action_state = require("telescope.actions.state")
	make_entry = require("telescope.make_entry")
	entry_display = require("telescope.pickers.entry_display")
end

local M = {}

-- ---------------------------------------------------------------------------
-- Stats tracking (frequency / recency)
-- ---------------------------------------------------------------------------

local STATS_FILE = vim.fn.stdpath("data") .. "/tuiter/stats.json"

local function load_stats()
	local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(STATS_FILE), "\n"))
	if ok and type(data) == "table" then
		return data
	end
	return { frequency = {}, recency = {} }
end

local function save_stats(stats)
	local ok = pcall(vim.fn.writefile, { vim.json.encode(stats) }, STATS_FILE)
	return ok
end

local function record_use(key)
	local stats = load_stats()
	stats.frequency[key] = (stats.frequency[key] or 0) + 1
	stats.recency[key] = os.time()
	save_stats(stats)
end

-- ---------------------------------------------------------------------------
-- Favorites
-- ---------------------------------------------------------------------------

local FAVS_FILE = vim.fn.stdpath("data") .. "/tuiter/favorites.json"

local function load_favs()
	local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(FAVS_FILE), "\n"))
	if ok and type(data) == "table" then
		return data
	end
	return {}
end

local function save_favs(favs)
	pcall(vim.fn.writefile, { vim.json.encode(favs) }, FAVS_FILE)
end

local function toggle_fav(key)
	local favs = load_favs()
	if favs[key] then
		favs[key] = nil
	else
		favs[key] = true
	end
	save_favs(favs)
	return favs[key]
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local METHOD_COLORS = {
	GET = "DiagnosticOk",
	POST = "DiagnosticInfo",
	PUT = "DiagnosticWarn",
	PATCH = "DiagnosticWarn",
	DELETE = "DiagnosticError",
}

local function truncate(s, len)
	if #s <= len then
		return s
	end
	return s:sub(1, len - 1) .. "…"
end

local function format_request(r)
	local favs = load_favs()
	local stats = load_stats()
	local key = r.method .. " " .. r.url
	local fav = favs[key] and "★ " or "  "
	local freq = stats.frequency[key] or 0
	local last = stats.recency[key]
	local recency = last and os.date("%m-%d %H:%M", last) or ""
	local name = r.name ~= "" and r.name or r.url
	local method = string.format("%-6s", r.method)
	return string.format("%s%s %-24s %s", fav, method, truncate(name, 24), recency)
end

local function request_entry_maker(opts)
	opts = opts or {}
	return function(r)
		local favs = load_favs()
		local key = r.method .. " " .. r.url
		local fav = favs[key] or false
		local displayer = entry_display.create({
			separator = " ",
			items = {
				{ width = 2 },   -- fav icon
				{ width = 6 },   -- method
				{ width = 24 },  -- name
				{ remaining = true }, -- url
			},
		})
		return {
			value = r,
			display = function(entry)
				local method_hl = METHOD_COLORS[r.method] or "Comment"
				return displayer({
					{ fav and "★" or " ", fav and "Constant" or "Comment" },
					{ r.method, method_hl },
					{ truncate(r.name ~= "" and r.name or r.url, 24), "Identifier" },
					{ r.name ~= "" and truncate(r.url, 30) or "", "Comment" },
				})
			end,
			ordinal = (r.name .. " " .. r.url .. " " .. r.method):lower(),
			method = r.method,
			url = r.url,
			name = r.name,
			is_fav = fav,
			line = r.line,
		}
	end
end

local function history_entry_maker()
	return function(e)
		local displayer = entry_display.create({
			separator = " ",
			items = {
				{ width = 12 },  -- date
				{ width = 6 },   -- method
				{ remaining = true }, -- url
			},
		})
		return {
			value = e,
			display = function(entry)
				local status = e.status or 0
				local status_hl = status >= 200 and status < 400 and "DiagnosticOk" or "DiagnosticError"
				return displayer({
					{ os.date("%m-%d %H:%M", e.ts), "Comment" },
					{ e.method, METHOD_COLORS[e.method] or "Comment" },
					{ truncate(e.url, 40), status_hl },
				})
			end,
			ordinal = (e.url .. " " .. e.method):lower(),
			spec = e.spec,
			ts = e.ts,
			status = e.status,
		}
	end
end

local function env_entry_maker()
	return function(n)
		return {
			value = n,
			display = n,
			ordinal = n:lower(),
		}
	end
end

local function collection_entry_maker()
	return function(c)
		return {
			value = c,
			display = string.format("%s (%d files)", c.name, #c.files),
			ordinal = c.name:lower(),
			path = c.path,
			files = c.files,
		}
	end
end

local function template_entry_maker()
	return function(t)
		return {
			value = t,
			display = string.format("%-8s %s", t.method, t.name),
			ordinal = (t.name .. " " .. t.method):lower(),
			method = t.method,
			content = t.content,
		}
	end
end

local function command_entry_maker()
	return function(c)
		return {
			value = c,
			display = string.format("%-20s %s", c.cmd, c.desc),
			ordinal = (c.cmd .. " " .. c.desc):lower(),
			cmd = c.cmd,
			keymap = c.keymap,
		}
	end
end

-- ---------------------------------------------------------------------------
-- Picker: requests
-- ---------------------------------------------------------------------------

function M.requests(opts)
	opts = opts or {}
	lazy()
	local parser = require("tuiter.parser")
	local collections_mod = require("tuiter.collections")
	local reqs = parser.parse_lines(vim.api.nvim_buf_get_lines(0, 0, -1, false))

	-- Filter by tag if specified
	if opts.tag then
		local filtered = {}
		for _, r in ipairs(reqs) do
			local tags = collections_mod.parse_tags(r)
			for _, tag in ipairs(tags) do
				if tag:lower():find(opts.tag:lower(), 1, true) then
					table.insert(filtered, r)
					break
				end
			end
		end
		reqs = filtered
	end

	-- Filter by method if specified
	if opts.method then
		local filtered = {}
		for _, r in ipairs(reqs) do
			if r.method:upper() == opts.method:upper() then
				table.insert(filtered, r)
			end
		end
		reqs = filtered
	end

	-- Filter favorites only
	if opts.favorites then
		local favs = load_favs()
		local filtered = {}
		for _, r in ipairs(reqs) do
			local key = r.method .. " " .. r.url
			if favs[key] then
				table.insert(filtered, r)
			end
		end
		reqs = filtered
	end

	if #reqs == 0 then
		vim.notify("Tuiter: no requests found", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end

	pickers
		.new({}, {
			prompt_title = "tuiter requests",
			finder = finders.new_table({
				results = reqs,
				entry_maker = request_entry_maker(opts),
			}),
			sorter = conf.generic_sorter({}),
			previewer = nil,
			attach_mappings = function(prompt_bufnr, map)
				-- Send request
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						record_use(entry.value.method .. " " .. entry.value.url)
						require("tuiter").resend(entry.value)
					end
				end)

				-- Go to file
				map("i", "<C-o>", function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry and entry.value.line then
						vim.api.nvim_win_set_cursor(0, { entry.value.line, 0 })
					end
				end)

				-- Toggle favorite
				map("i", "<C-f>", function()
					local entry = action_state.get_selected_entry()
					if entry then
						local key = entry.value.method .. " " .. entry.value.url
						local is_fav = toggle_fav(key)
						vim.notify(
							is_fav and "Tuiter: added to favorites" or "Tuiter: removed from favorites",
							vim.log.levels.INFO,
							{ title = "Tuiter" }
						)
						-- Refresh picker
						actions.close(prompt_bufnr)
						M.requests(opts)
					end
				end)

				-- Copy as curl
				map("i", "<C-s>", function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						local client = require("tuiter.client")
						local config = require("tuiter").opts()
						vim.fn.setreg('"', client.curl_command(entry.value, config.curl))
						vim.notify("Tuiter: curl command copied", vim.log.levels.INFO, { title = "Tuiter" })
					end
				end)

				-- Copy as code snippet
				map("i", "<C-c>", function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						require("tuiter").copy_code_for(entry.value)
					end
				end)

				-- Preview response (open in float)
				map("i", "<C-t>", function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						require("tuiter").toggle_response()
					end
				end)

				-- Multi-select with Tab
				map("i", "<Tab>", function()
					local entry = action_state.get_selected_entry()
					if entry then
						action_state.toggle_selection(prompt_bufnr)
						actions.move_selection_next(prompt_bufnr)
					end
				end)

				map("i", "<S-Tab>", function()
					local entry = action_state.get_selected_entry()
					if entry then
						action_state.toggle_selection(prompt_bufnr)
						actions.move_selection_previous(prompt_bufnr)
					end)
				end)

				-- Run all selected
				map("i", "<C-a>", function()
					local picker = action_state.get_current_picker(prompt_bufnr)
					local selections = picker:get_multi_selection()
					actions.close(prompt_bufnr)
					if #selections > 0 then
						for _, sel in ipairs(selections) do
							record_use(sel.value.method .. " " .. sel.value.url)
							require("tuiter").resend(sel.value)
						end
					else
						-- Run all requests in buffer
						require("tuiter").run_all()
					end
				end)

				return true
			end,
		})
		:find()
end

-- ---------------------------------------------------------------------------
-- Picker: history
-- ---------------------------------------------------------------------------

function M.history()
	lazy()
	local history = require("tuiter.history")
	local entries = history.load()

	if #entries == 0 then
		vim.notify("Tuiter: no history yet", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end

	-- Sort by time (newest first)
	table.sort(entries, function(a, b)
		return (a.ts or 0) > (b.ts or 0)
	end)

	pickers
		.new({}, {
			prompt_title = "tuiter history",
			finder = finders.new_table({
				results = entries,
				entry_maker = history_entry_maker(),
			}),
			sorter = conf.generic_sorter({}),
			previewer = nil,
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						record_use(entry.value.method .. " " .. entry.value.url)
						require("tuiter").resend(entry.value.spec)
					end
				end)

				-- Delete from history
				map("i", "<C-d>", function()
					local entry = action_state.get_selected_entry()
					if entry then
						history.delete(entry.value)
						vim.notify("Tuiter: deleted from history", vim.log.levels.INFO, { title = "Tuiter" })
						actions.close(prompt_bufnr)
						M.history()
					end
				end)

				-- Copy as curl
				map("i", "<C-s>", function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry and entry.value.spec then
						local client = require("tuiter.client")
						local config = require("tuiter").opts()
						vim.fn.setreg('"', client.curl_command(entry.value.spec, config.curl))
						vim.notify("Tuiter: curl command copied", vim.log.levels.INFO, { title = "Tuiter" })
					end
				end)

				return true
			end,
		})
		:find()
end

-- ---------------------------------------------------------------------------
-- Picker: environments
-- ---------------------------------------------------------------------------

function M.env()
	lazy()
	local client = require("tuiter.client")
	local cwd = vim.fn.getcwd()
	local envs = client.envs(cwd, require("tuiter").opts())

	if #envs == 0 then
		vim.notify("Tuiter: no environments found", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end

	pickers
		.new({}, {
			prompt_title = "tuiter environments",
			finder = finders.new_table({
				results = envs,
				entry_maker = env_entry_maker(),
			}),
			sorter = conf.generic_sorter({}),
			previewer = nil,
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						record_use("env:" .. entry.value)
						require("tuiter.client").set_env(entry.value, cwd, require("tuiter").opts())
						vim.notify(
							string.format("Tuiter: environment set to %q", entry.value),
							vim.log.levels.INFO,
							{ title = "Tuiter" }
						)
					end
				end)

				return true
			end,
		})
		:find()
end

-- ---------------------------------------------------------------------------
-- Picker: collections
-- ---------------------------------------------------------------------------

function M.collections()
	lazy()
	local collections_mod = require("tuiter.collections")
	local cols = collections_mod.list_collections(vim.fn.getcwd())

	if #cols == 0 then
		vim.notify("Tuiter: no collections found", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end

	pickers
		.new({}, {
			prompt_title = "tuiter collections",
			finder = finders.new_table({
				results = cols,
				entry_maker = collection_entry_maker(),
			}),
			sorter = conf.generic_sorter({}),
			previewer = nil,
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						-- Show requests from this collection
						M.collection_requests(entry.value)
					end
				end)

				-- New collection
				map("i", "<C-n>", function()
					actions.close(prompt_bufnr)
					require("tuiter").collection_new()
				end)

				-- Delete collection
				map("i", "<C-d>", function()
					local entry = action_state.get_selected_entry()
					if entry then
						local confirm = vim.fn.confirm(
							"Delete collection '" .. entry.value.name .. "'?",
							"&Yes\n&No",
							2
						)
						if confirm == 1 then
							vim.fn.delete(entry.value.path, "rf")
							vim.notify("Tuiter: deleted collection", vim.log.levels.INFO, { title = "Tuiter" })
							actions.close(prompt_bufnr)
							M.collections()
						end
					end
				end)

				return true
			end,
		})
		:find()
end

--- Show requests from a specific collection
---@param collection table
function M.collection_requests(collection)
	lazy()
	local parser = require("tuiter.parser")
	local reqs = {}

	-- Parse all .http files in the collection
	for _, file in ipairs(collection.files) do
		local lines = vim.fn.readfile(file.path)
		local parsed = parser.parse_lines(lines)
		for _, r in ipairs(parsed) do
			r._file = file.path
			table.insert(reqs, r)
		end
	end

	if #reqs == 0 then
		vim.notify("Tuiter: no requests in collection", vim.log.levels.WARN, { title = "Tuiter" })
		return
	end

	pickers
		.new({}, {
			prompt_title = "tuiter: " .. collection.name,
			finder = finders.new_table({
				results = reqs,
				entry_maker = function(r)
					return {
						value = r,
						display = string.format("%-6s %s", r.method, r.name ~= "" and r.name or r.url),
						ordinal = (r.name .. " " .. r.url .. " " .. r.method):lower(),
						method = r.method,
						url = r.url,
						name = r.name,
						line = r.line,
						file = r._file,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = nil,
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						-- Open file and send request
						vim.cmd("edit " .. vim.fn.fnameescape(entry.value.file))
						vim.api.nvim_win_set_cursor(0, { entry.value.line, 0 })
						require("tuiter").run({ lnum = entry.value.line })
					end
				end)

				-- Go to file
				map("i", "<C-o>", function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						vim.cmd("edit " .. vim.fn.fnameescape(entry.value.file))
						vim.api.nvim_win_set_cursor(0, { entry.value.line, 0 })
					end
				end)

				return true
			end,
		})
		:find()
end

-- ---------------------------------------------------------------------------
-- Picker: templates
-- ---------------------------------------------------------------------------

function M.templates()
	lazy()
	local templates_mod = require("tuiter.templates")
	local all = templates_mod.all()

	pickers
		.new({}, {
			prompt_title = "tuiter templates",
			finder = finders.new_table({
				results = all,
				entry_maker = template_entry_maker(),
			}),
			sorter = conf.generic_sorter({}),
			previewer = nil,
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						record_use("template:" .. entry.value.name)
						templates_mod.insert(entry.value.name)
					end
				end)

				-- Save current request as template
				map("i", "<C-s>", function()
					actions.close(prompt_bufnr)
					require("tuiter").snippet_save()
				end)

				-- Delete template (only custom)
				map("i", "<C-d>", function()
					local entry = action_state.get_selected_entry()
					if entry and not entry.value.builtin then
						templates_mod.delete(entry.value.name)
						vim.notify("Tuiter: deleted template", vim.log.levels.INFO, { title = "Tuiter" })
						actions.close(prompt_bufnr)
						M.templates()
					end
				end)

				return true
			end,
		})
		:find()
end

-- ---------------------------------------------------------------------------
-- Picker: commands
-- ---------------------------------------------------------------------------

function M.commands()
	lazy()
	local commands = {
		{ cmd = "TuiterRun", desc = "Send request under cursor", keymap = "<leader>is" },
		{ cmd = "TuiterRunAll", desc = "Run all requests", keymap = "<leader>ia" },
		{ cmd = "TuiterCancel", desc = "Cancel in-flight requests", keymap = "<leader>ic" },
		{ cmd = "TuiterHistory", desc = "Browse request history", keymap = "<leader>ih" },
		{ cmd = "TuiterEnv", desc = "Select environment", keymap = "<leader>ie" },
		{ cmd = "TuiterResponse", desc = "Toggle response window", keymap = "<leader>ir" },
		{ cmd = "TuiterVars", desc = "Show resolved variables", keymap = "<leader>iv" },
		{ cmd = "TuiterSaveBody", desc = "Save response body to file" },
		{ cmd = "TuiterCopyAs", desc = "Copy request as code snippet" },
		{ cmd = "TuiterStream", desc = "Stream SSE request" },
		{ cmd = "TuiterWatch", desc = "Re-run request every N seconds" },
		{ cmd = "TuiterJUnit", desc = "Export results as JUnit XML" },
		{ cmd = "TuiterCI", desc = "Run all + exit on failure (CI)" },
		{ cmd = "TuiterScaffold", desc = "Open scaffolded .http buffer" },
		{ cmd = "TuiterFormat", desc = "Pretty-print request body JSON" },
		{ cmd = "TuiterImportPostman", desc = "Convert Postman collection to .http" },
		{ cmd = "TuiterImportOpenapi", desc = "Convert OpenAPI spec to .http" },
		{ cmd = "TuiterImportCurl", desc = "Paste curl command → .http buffer" },
		{ cmd = "TuiterCollection", desc = "Manage request collections", keymap = "<leader>ic" },
		{ cmd = "TuiterSnippet", desc = "Manage request templates", keymap = "<leader>it" },
	}

	pickers
		.new({}, {
			prompt_title = "tuiter commands",
			finder = finders.new_table({
				results = commands,
				entry_maker = command_entry_maker(),
			}),
			sorter = conf.generic_sorter({}),
			previewer = nil,
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						vim.cmd(entry.value.cmd)
					end
				end)

				-- Copy command to clipboard
				map("i", "<C-y>", function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						vim.fn.setreg('"', entry.value.cmd)
						vim.notify("Tuiter: command copied", vim.log.levels.INFO, { title = "Tuiter" })
					end
				end)

				return true
			end,
		})
		:find()
end

return M