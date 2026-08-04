-- Telescope extension: `:Telescope tuiter history|requests|env`.
-- Enable with: require("telescope").load_extension("tuiter")
local tuiter_pickers = require("tuiter.pickers")

return require("telescope").register_extension({
	setup = function() end,
	exports = {
		history = tuiter_pickers.history,
		requests = tuiter_pickers.requests,
		env = tuiter_pickers.env,
	},
})
