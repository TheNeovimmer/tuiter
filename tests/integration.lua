-- Integration test: real curl send against a local server + response UI.
-- Run: nvim --headless -l tests/integration.lua
package.path = "./lua/?.lua;" .. package.path
local client = require("tuiter.client")
local ui = require("tuiter.ui")

local server = vim.system({ "python3", "tests/server.py" }, {}, function() end)

local up = vim.wait(3000, function()
	return vim.fn.system({ "curl", "-s", "-o", "/dev/null", "http://127.0.0.1:8999/up" }) == ""
		and vim.fn.system("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8999/up") == "200"
end, 100)
assert(up, "test server did not start on :8999")

local done, results = false, {}
local spec = { method = "GET", url = "http://127.0.0.1:8999/api?x=1", headers = {}, body = nil, vars = {}, cwd = "." }
client.send(spec, { timeout = 10 }, ".", function(resp)
	results.get = resp
	client.send(
		{
			method = "POST",
			url = "http://127.0.0.1:8999/users",
			headers = { ["Content-Type"] = "application/json" },
			body = '{"hello":"world"}',
			vars = {},
			cwd = ".",
		},
		{ timeout = 10 },
		".",
		function(r)
			results.post = r
			done = true
		end
	)
end)
assert(
	vim.wait(5000, function()
		return done
	end),
	"requests timed out"
)

local g = results.get
assert(g.status == 200, "GET status: " .. vim.inspect(g))
assert(vim.json.decode(g.body).path == "/api?x=1", "GET body: " .. vim.inspect(g.body))
assert(g.headers:match("^HTTP/1.1 200"), "GET headers: " .. vim.inspect(g.headers))

local p = results.post
assert(p.status == 201, "POST status: " .. vim.inspect(p))
assert(vim.json.decode(p.body).echo == '{"hello":"world"}', "POST echo: " .. vim.inspect(p.body))

-- response UI opens/closes headlessly
ui.show(g, spec, function() end)
assert(ui.state.body_win and vim.api.nvim_win_is_valid(ui.state.body_win), "body window missing")
assert(ui.state.head_win and vim.api.nvim_win_is_valid(ui.state.head_win), "headers window missing")
ui.close()
assert(not (ui.state.body_win and vim.api.nvim_win_is_valid(ui.state.body_win)), "close failed")

server:kill()
print("ALL INTEGRATION TESTS PASSED")
