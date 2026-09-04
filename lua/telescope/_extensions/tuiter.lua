-- Telescope extension: `:Telescope tuiter history|requests|env|collections|templates|commands`.
-- Enable with: require("telescope").load_extension("tuiter")
local tuiter_pickers = require("tuiter.pickers")

return require("telescope").register_extension({
	setup = function() end,
	exports = {
		history = tuiter_pickers.history,
		requests = tuiter_pickers.requests,
		env = tuiter_pickers.env,
		collections = tuiter_pickers.collections,
		templates = tuiter_pickers.templates,
		commands = tuiter_pickers.commands,
	},
})