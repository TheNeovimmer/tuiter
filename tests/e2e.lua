-- E2E smoke test through the real plugin entrypoints (plugin/ + ftplugin/).
-- Run: nvim --headless -l tests/e2e.lua   (start tests/server.py first)
-- Verifies: commands, filetype detection, buffer keymaps, diagnostics,
-- GraphQL parsing + send, TuiterCopyAs snippet copy.
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local rt = vim.fn.getcwd()
vim.opt.runtimepath:prepend(rt)
vim.opt.packpath:prepend(rt)
vim.cmd("filetype on") -- make filetype detection deterministic in -l script mode

-- start the local test server (also used by tests/integration.lua)
local server = vim.system({ "python3", "tests/server.py" }, {}, function() end)
assert(
	vim.wait(3000, function()
		return vim.fn.system("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8999/up") == "200"
	end, 100),
	"test server did not start on :8999"
)

local failed = 0
local function eq(got, want, label)
	if got ~= want then
		failed = failed + 1
		print(("FAIL %s: got %q, want %q"):format(label, tostring(got), tostring(want)))
	end
end

-- plugin/tuiter.lua registers commands + filetype detection
vim.cmd("runtime! plugin/tuiter.lua")
eq(vim.fn.exists(":Tuiter") == 2, true, ":Tuiter command")
eq(vim.fn.exists(":TuiterCopyAs") == 2, true, ":TuiterCopyAs command")
eq(vim.fn.exists(":TuiterRunAll") == 2, true, ":TuiterRunAll command")
eq(vim.fn.exists(":TuiterImportCurl") == 2, true, ":TuiterImportCurl command")

-- open demo.http -> filetype + keymaps + ftplugin diagnostics
local hbuf = vim.fn.bufadd("examples/demo.http")
vim.cmd("buffer " .. hbuf)
vim.cmd("doautocmd BufReadPost")
vim.cmd("doautocmd FileType http")
-- -l script mode skips the runtime's FileType->ftplugin dispatch; source it
-- directly (idempotent: vim.keymap.set replaces same-key mappings)
vim.cmd("runtime! ftplugin/http.lua")
eq(vim.bo[hbuf].filetype, "http", "demo.http filetype")
eq(vim.bo[hbuf].omnifunc:match("tuiter") ~= nil, true, "omnifunc wired")
local kmaps = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
	if m.desc and m.desc:match("^Tuiter") then
		kmaps[#kmaps + 1] = m.desc
	end
end
eq(#kmaps >= 8, true, "http buffer keymaps: " .. #kmaps)
-- diagnostics: clean demo -> no warnings
eq(#vim.diagnostic.get(hbuf), 0, "no diagnostics in clean demo.http")
-- introduce an error line -> warning appears
vim.api.nvim_buf_set_lines(hbuf, 0, 1, false, { "GET", "### x" })
vim.cmd("write")
eq(#vim.diagnostic.get(hbuf) >= 1, true, "diagnostic fires on bad line")
vim.api.nvim_buf_set_lines(hbuf, 0, 2, false, { "### List users (GET)" })
vim.cmd("write")
eq(#vim.diagnostic.get(hbuf), 0, "diagnostic clears")

-- :TuiterCopyAs python on the request under the cursor
vim.api.nvim_win_set_cursor(0, { 7, 0 }) -- a GET line in demo.http
vim.cmd("TuiterCopyAs python")
local reg = vim.fn.getreg('"')
eq(reg:match("import requests") ~= nil, true, "copy-as python via command")

-- GraphQL buffer: filetype, keymaps, send against the local server
vim.fn.writefile({
	"# @url http://127.0.0.1:8999/users",
	"",
	"query GetEcho {",
	'  echo(message: "hi") { message }',
	"}",
}, "examples/__e2e__.graphql")
vim.cmd("edit examples/__e2e__.graphql")
vim.bo[0].filetype = "graphql"
vim.cmd("doautocmd FileType graphql")
vim.cmd("runtime! ftplugin/graphql.lua")
eq(vim.bo[0].filetype, "graphql", "graphql filetype")
eq(vim.bo[0].commentstring, "# %s", "graphql commentstring")
local gkm = 0
for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
	if m.desc and m.desc:match("^Tuiter") then
		gkm = gkm + 1
	end
end
eq(gkm >= 8, true, "graphql buffer keymaps: " .. gkm)
vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- the query operation
require("tuiter").run()
local ok = vim.wait(5000, function()
	local r = require("tuiter.client").state.response
	return r and r.status and r.status > 0
end)
eq(ok, true, "graphql send completed")
local resp = require("tuiter.client").state.response
eq(resp.status, 201, "graphql send status")
local payload = vim.json.decode(resp.body)
eq(payload.method, "POST", "graphql sent as POST")
eq(payload.echo:match('"query"') ~= nil, true, "graphql body is JSON query envelope")

os.remove("examples/__e2e__.graphql")

-- OAuth2 401 auto-refresh: client-credentials token -> /protected 401s with
-- the cc token -> tuiter re-fetches via the refresh grant -> 200
local oauth = {
	type = "oauth2",
	token_url = "http://127.0.0.1:8999/oauth-token",
	client_id = "cid",
	client_secret = "cs",
	scope = "",
}
local oauth_file = vim.fn.stdpath("data") .. "/tuiter/oauth.json"
local oauth_saved = vim.fn.filereadable(oauth_file) == 1 and vim.fn.readfile(oauth_file) or nil
require("tuiter.auth").invalidate(oauth)
require("tuiter.client").state.response = nil -- clear the previous test's response
require("tuiter").resend({ method = "GET", url = "http://127.0.0.1:8999/protected", auth = oauth, no_log = true })
local ok2 = vim.wait(8000, function()
	local r = require("tuiter.client").state.response
	return r and r.status and r.status > 0
end)
eq(ok2, true, "oauth2 request completed")
local r2 = require("tuiter.client").state.response
eq(r2.status, 200, "oauth2 401 auto-refreshed via refresh grant")
eq(vim.json.decode(r2.body).ok == true, true, "oauth2 refreshed token accepted")

-- multipart file upload through the real send path (relative @path)
require("tuiter.client").state.response = nil
require("tuiter").resend({
	method = "POST",
	url = "http://127.0.0.1:8999/users",
	headers = { ["Content-Type"] = "multipart/form-data" },
	body = "name=ada\npayload=@tests/fixtures/upload.txt",
	no_log = true,
})
local ok3 = vim.wait(8000, function()
	local r = require("tuiter.client").state.response
	return r and r.status and r.status > 0
end)
eq(ok3, true, "multipart upload completed")
local r3 = require("tuiter.client").state.response
eq(r3.status, 201, "multipart upload status")
local echo = vim.json.decode(r3.body).echo or ""
eq(echo:match("file content") ~= nil, true, "multipart file field sent as file content")
if oauth_saved then
	vim.fn.writefile(oauth_saved, oauth_file)
else
	os.remove(oauth_file)
end

if failed == 0 then
	print("ALL E2E TESTS PASSED")
else
	print(failed .. " FAILURES")
	os.exit(1)
end
