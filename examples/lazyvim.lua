-- LazyVim / lazy.nvim recommended setup for tuiter with the pro features.
-- Copy to ~/.config/nvim/lua/plugins/tuiter.lua
return {
	"TheNeovimmer/tuiter",
	branch = "main",
	dependencies = {}, -- pure Lua + curl, zero plugin deps
	cmd = {
		"Tuiter",
		"TuiterRun",
		"TuiterRunAll",
		"TuiterCancel",
		"TuiterCopyAs",
		"TuiterSaveBody",
		"TuiterHistory",
		"TuiterResponse",
		"TuiterEnv",
		"TuiterStream",
		"TuiterWatch",
		"TuiterJUnit",
		"TuiterCI",
		"TuiterScaffold",
		"TuiterFormat",
		"TuiterImportPostman",
		"TuiterImportOpenapi",
	},
	ft = { "http", "graphql" },
	opts = {
		curl = { timeout = 30, insecure = false, max_redirects = 8, cookie_jar = true, compressed = true },
		run_all = { concurrency = 4, delay = 100 }, -- parallel collection runner
		keymaps = {
			run = "<leader>is",
			list = "<leader>il",
			run_all = "<leader>ia",
			cancel = "<leader>ic",
			help = "<leader>ik",
			history = "<leader>ih",
			env = "<leader>ie",
			response = "<leader>ir",
		},
	},
	keys = {
		-- picker-based history (telescope users); vim.ui.select (LazyVim →
		-- snacks picker) is already used by :TuiterHistory when telescope is off
		{ "<leader>ih", function() require("telescope").load_extension("tuiter").history() end, desc = "Tuiter history" },
		{ "<leader>iw", "<Cmd>TuiterWatch 5<CR>", desc = "Tuiter watch (healthcheck)" },
	},
	init = function()
		-- format the request body JSON on save (conform.nvim)
		local ok, conform = pcall(require, "conform")
		if ok then
			conform.formatters_by_ft.http = { "jq" } -- or "prettierd"
		end
	end,
}
