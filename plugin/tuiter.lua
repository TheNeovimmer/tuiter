-- tuiter plugin entry: commands + filetype detection.
require("tuiter").setup()

vim.filetype.add({ extension = { http = "http", graphql = "graphql", gql = "graphql" } })

vim.api.nvim_create_user_command("Tuiter", function()
	require("tuiter").sidebar()
end, { desc = "Toggle the tuiter request sidebar" })

vim.api.nvim_create_user_command("TuiterRun", function(a)
	local lnum = tonumber(a.args)
	require("tuiter").run(lnum and { lnum = lnum } or {})
end, { nargs = "?", desc = "Send the request under the cursor (TuiterRun [lnum])" })

vim.api.nvim_create_user_command("TuiterRunAll", function()
	require("tuiter").run_all()
end, { desc = "Run every request in the buffer and show a summary" })

vim.api.nvim_create_user_command("TuiterCancel", function()
	require("tuiter").cancel()
end, { desc = "Cancel in-flight requests" })

vim.api.nvim_create_user_command("TuiterCopyAs", function(a)
	require("tuiter").copy_as(a.args ~= "" and a.args or nil)
end, {
	nargs = "?",
	complete = function()
		return { "curl", "python", "js", "ts", "go", "rust", "php", "graphql" }
	end,
	desc = "Copy the request under the cursor as a code snippet",
})

vim.api.nvim_create_user_command("TuiterSaveBody", function()
	require("tuiter.ui").save_body()
end, { desc = "Save the last response body to a file" })

vim.api.nvim_create_user_command("TuiterHistory", function()
	require("tuiter").history()
end, { desc = "Browse tuiter request history" })

vim.api.nvim_create_user_command("TuiterResponse", function()
	require("tuiter").toggle_response()
end, { desc = "Toggle the tuiter response window" })

vim.api.nvim_create_user_command("TuiterEnv", function()
	require("tuiter").select_env()
end, { desc = "Select a tuiter environment" })

vim.api.nvim_create_user_command("TuiterStream", function()
	require("tuiter").stream()
end, { desc = "Stream the request under the cursor (SSE)" })

vim.api.nvim_create_user_command("TuiterWatch", function(a)
	require("tuiter").watch({ seconds = tonumber(a.args) })
end, {
	nargs = "?",
	desc = "Re-run the request under the cursor every N seconds (toggle to stop)",
})

vim.api.nvim_create_user_command("TuiterJUnit", function(a)
	require("tuiter").junit(a.args ~= "" and a.args or nil)
end, {
	nargs = "?",
	desc = "Export the last run-all results as JUnit XML (TuiterJUnit [path])",
})

vim.api.nvim_create_user_command("TuiterCI", function()
	require("tuiter").ci()
end, { desc = "Run all requests and exit non-zero on failure (CI); writes tuiter-junit.xml" })

vim.api.nvim_create_user_command("TuiterScaffold", function()
	require("tuiter").scaffold()
end, { desc = "Open a scaffolded .http buffer" })

vim.api.nvim_create_user_command("TuiterFormat", function()
	require("tuiter").format()
end, { desc = "Pretty-print the JSON body of the request under the cursor" })

vim.api.nvim_create_user_command("TuiterImportPostman", function(a)
	require("tuiter").import("postman", a.args ~= "" and a.args or nil)
end, {
	nargs = "?",
	complete = "file",
	desc = "Convert a Postman collection JSON to a .http buffer",
})

vim.api.nvim_create_user_command("TuiterImportOpenapi", function(a)
	require("tuiter").import("openapi", a.args ~= "" and a.args or nil)
end, {
	nargs = "?",
	complete = "file",
	desc = "Convert an OpenAPI spec JSON to a .http buffer",
})

vim.api.nvim_create_user_command("TuiterVars", function()
	require("tuiter").vars()
end, { desc = "Show the resolved values of every {{var}} in the request under the cursor" })

vim.api.nvim_create_user_command("TuiterImportCurl", function()
	require("tuiter").import_curl()
end, { desc = "Paste a curl command (DevTools / docs / gh api -i) and convert it to a .http buffer" })
