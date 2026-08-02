-- Integration test: real curl send against a local server + response UI.
-- Run: nvim --headless -l tests/integration.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local client = require("tuiter.client")
local ui = require("tuiter.ui")

local failed = 0
local function eq(got, want, label)
	if got ~= want then
		failed = failed + 1
		print(("FAIL %s: got %q, want %q"):format(label, tostring(got), tostring(want)))
	end
end

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

-- cookie jar: /cookie sets a cookie; a later request on the same cwd
-- sends it back (server echoes the Cookie header)
local cdone, cj = false, nil
client.send(
	{ method = "GET", url = "http://127.0.0.1:8999/cookie", headers = {}, body = nil, vars = {}, cwd = "." },
	{ timeout = 10 },
	".",
	function(r)
		assert(r.status == 200, "cookie endpoint status")
		client.send(
			{ method = "GET", url = "http://127.0.0.1:8999/api?jar=1", headers = {}, body = nil, vars = {}, cwd = "." },
			{ timeout = 10 },
			".",
			function(r2)
				cj = vim.json.decode(r2.body).cookie
				cdone = true
			end
		)
	end
)
assert(
	vim.wait(5000, function()
		return cdone
	end),
	"cookie jar requests timed out"
)
eq(cj, "tuiter_test=1", "cookie persisted across requests")

-- multipart: -F fields reach the server raw
local mdone, mres = false, nil
client.send(
	{
		method = "POST",
		url = "http://127.0.0.1:8999/users",
		headers = { ["Content-Type"] = "multipart/form-data" },
		body = "name=ada\nrole=admin",
		vars = {},
		cwd = ".",
	},
	{ timeout = 10 },
	".",
	function(r)
		mres = r.body
		mdone = true
	end
)
assert(
	vim.wait(5000, function()
		return mdone
	end),
	"multipart request timed out"
)
local mecho = vim.json.decode(mres).echo
assert(mecho:match('name="name"') and mecho:match("ada"), "multipart field name=ada: " .. mecho)
assert(mecho:match('name="role"') and mecho:match("admin"), "multipart field role=admin")

-- response UI opens/closes headlessly
ui.show(g, spec, {})
assert(ui.state.body_win and vim.api.nvim_win_is_valid(ui.state.body_win), "body window missing")
assert(ui.state.head_win and vim.api.nvim_win_is_valid(ui.state.head_win), "tab bar window missing")
local tab_buf = vim.api.nvim_win_get_buf(ui.state.head_win)
eq(
	table.concat(vim.api.nvim_buf_get_lines(tab_buf, 0, -1, false), "\n"):match("Body") ~= nil,
	true,
	"tab bar shows Body"
)
-- tab switching: headers then timeline then body
ui.set_tab(2)
local cbuf = vim.api.nvim_win_get_buf(ui.state.body_win)
eq(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false)[1]:match("^HTTP/1.1 200") ~= nil, true, "headers tab")
ui.set_tab(3)
eq(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false)[1]:match("DNS lookup") ~= nil, true, "timeline tab")
ui.set_tab(1)
eq(table.concat(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false), "\n"):match('"path"') ~= nil, true, "body tab back")
ui.close()
assert(not (ui.state.body_win and vim.api.nvim_win_is_valid(ui.state.body_win)), "close failed")

-- response chaining: last response feeds {{$body.*}} / {{$status}}
client.record_response(g)
eq(client.substitute("{{$body.method}}", {}), "GET", "chain method")
eq(client.substitute("{{$body.path}}", {}), "/api?x=1", "chain path")
eq(client.substitute("{{$status}}", {}), "200", "chain status")

-- run all: summary window opens with results
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
	"### Ping",
	"GET http://127.0.0.1:8999/api",
	"",
	"### Post",
	"POST http://127.0.0.1:8999/users",
	"Content-Type: application/json",
	"",
	'{"x":1}',
})
local tuiter = require("tuiter")
tuiter.run_all()
local ran = vim.wait(8000, function()
	return ui.state.summary_win and vim.api.nvim_win_is_valid(ui.state.summary_win)
end)
assert(ran, "run_all summary window")
assert(ui.state.results["http://127.0.0.1:8999/api"] == 200, "run_all GET marked")
assert(ui.state.results["http://127.0.0.1:8999/users"] == 201, "run_all POST marked")
pcall(vim.api.nvim_win_close, ui.state.summary_win, true)
ui.state.summary_win = nil

-- favorites toggle + persistence roundtrip
ui.toggle_fav("http://fav.test/x")
assert(ui.state.favs["http://fav.test/x"] == true, "favorite set")
ui.toggle_fav("http://fav.test/x")
assert(ui.state.favs["http://fav.test/x"] == nil, "favorite unset")

-- cancel an in-flight request
client.cancel()
assert(next(client.state.procs) == nil, "procs empty before cancel test")
local canceled_done, cres = false, nil
client.send(
	{ method = "GET", url = "http://127.0.0.1:8999/slow", headers = {}, body = nil, vars = {}, cwd = "." },
	{ timeout = 10 },
	".",
	function(r)
		canceled_done = true
		cres = r
	end
)
assert(
	vim.wait(1000, function()
		return next(client.state.procs) ~= nil
	end),
	"request in flight"
)
client.cancel()
assert(
	vim.wait(4000, function()
		return canceled_done
	end),
	"cancel callback fired"
)
eq(cres.ok, false, "canceled request not ok")
eq(cres.status, 0, "canceled request has no status")
assert(next(client.state.procs) == nil, "procs cleared after cancel")

-- sidebar opens/closes
local parser = require("tuiter.parser")
ui.show_sidebar(
	parser.parse_lines({
		"### Get",
		"GET http://127.0.0.1:8999/api",
		"",
		"### Post",
		"POST http://127.0.0.1:8999/users",
		"",
	}),
	{
		title = "test",
		run = function() end,
		go_to = function() end,
	}
)
assert(ui.sidebar_is_open(), "sidebar open")
-- filter narrows the list and back
ui.set_filter("post")
eq(#vim.api.nvim_buf_get_lines(ui.state.sidebar_buf, 0, -1, false), 1, "sidebar filter narrows")
ui.set_filter("")
eq(#vim.api.nvim_buf_get_lines(ui.state.sidebar_buf, 0, -1, false), 2, "sidebar filter cleared")
ui.close_sidebar()
assert(not ui.sidebar_is_open(), "sidebar close")

server:kill()
if failed == 0 then
	print("ALL INTEGRATION TESTS PASSED")
else
	print(failed .. " FAILURES")
	os.exit(1)
end
