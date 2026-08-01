-- tuiter plugin entry: commands + filetype detection.
require("tuiter").setup()

vim.filetype.add({ extension = { http = "http" } })

vim.api.nvim_create_user_command("Tuiter", function()
	require("tuiter").toggle_response()
end, { desc = "Toggle the tuiter response window" })

vim.api.nvim_create_user_command("TuiterRun", function(a)
	local lnum = tonumber(a.args)
	require("tuiter").run(lnum and { lnum = lnum } or {})
end, { nargs = "?", desc = "Send the request under the cursor (TuiterRun [lnum])" })

vim.api.nvim_create_user_command("TuiterHistory", function()
	require("tuiter").history()
end, { desc = "Browse tuiter request history" })

vim.api.nvim_create_user_command("TuiterEnv", function()
	require("tuiter").select_env()
end, { desc = "Select a tuiter environment" })
