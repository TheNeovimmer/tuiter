-- Unit tests: parser + substitution + response parsing + pretty-printing.
-- Run: nvim --headless -l tests/run.lua
package.path = "./lua/?.lua;" .. package.path
local parser = require("tuiter.parser")
local client = require("tuiter.client")

local failed = 0
local function eq(got, want, label)
	if got ~= want then
		failed = failed + 1
		print(("FAIL %s: got %q, want %q"):format(label, tostring(got), tostring(want)))
	end
end

-- --- parser ---
local lines = {
	"### Get users",
	"GET https://api.example.com/users/{{id}}",
	"Authorization: Bearer {{token}}",
	"Accept: application/json",
	"",
	'{"page": 1}',
	"",
	"### Create user",
	"@token = abc123",
	"POST https://api.example.com/users",
	"Content-Type: application/json",
	"",
	'{"name": "{{token}}"}',
}
local reqs = parser.parse_lines(lines)
eq(#reqs, 2, "request count")
local r1, r2 = reqs[1], reqs[2]
eq(r1.method, "GET", "method")
eq(r1.url, "https://api.example.com/users/{{id}}", "url")
eq(r1.headers.Authorization, "Bearer {{token}}", "header")
eq(r1.headers.Accept, "application/json", "header 2")
eq(r1.body, '{"page": 1}', "body")
eq(r1.name, "Get users", "name")
eq(r1.line, 1, "start line (the ### line)")
eq(r2.method, "POST", "post method")
eq(r2.vars.token, "abc123", "request var")
eq(r2.body, '{"name": "{{token}}"}', "post body")
eq(parser.at(reqs, 1).name, "Get users", "at line 1")
eq(parser.at(reqs, 8).url, r2.url, "at line 8 (### Create user)")
eq(parser.at(reqs, 20).url, r2.url, "past last request returns last")

-- implicit first request without ###
local reqs2 = parser.parse_lines({ "GET http://x.test/", "", "body" })
eq(#reqs2, 1, "implicit count")
eq(reqs2[1].url, "http://x.test/", "implicit url")
eq(reqs2[1].body, "body", "implicit body")

-- all-caps header must not be mistaken for a method line
local reqs3 = parser.parse_lines({ "### x", "CONNECTION: close", "GET /a" })
eq(reqs3[1].headers.CONNECTION, "close", "all-caps header")
eq(reqs3[1].url, "/a", "url after header")

-- demo file parses
local f = io.open("examples/demo.http", "r")
if f then
	local content = f:read("*a")
	f:close()
	eq(#parser.parse_lines(vim.split(content, "\n")), 4, "demo requests")
end

-- --- substitution ---
client.state.env = "prod"
client.state.env_vars = { token = "TOK123", host = "prod.example.com" }
eq(client.substitute("https://{{host}}/u/{{id}}", { id = 7 }), "https://prod.example.com/u/7", "subst")
eq(client.substitute("{{missing}}", {}), "{{missing}}", "unresolved kept")

-- --- response parsing ---
local out = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"ok":true}\n@@tuiter1@@ 200 0.123 15'
local resp = client.parse_response(out, "", 0, "@@tuiter1@@")
eq(resp.status, 200, "resp status")
eq(resp.time, 0.123, "resp time")
eq(resp.size, 15, "resp size")
eq(resp.body, '{"ok":true}', "resp body")
eq(resp.headers:match("^HTTP/1.1 200 OK"), "HTTP/1.1 200 OK", "resp headers")

-- failed connection: no stdout, error on stderr
local fail = client.parse_response("", "curl: (7) Failed to connect", 7, "@@tuiter1@@")
eq(fail.ok, false, "fail ok flag")
eq(fail.status, 0, "fail status")
eq(fail.error:match("Failed to connect") ~= nil, true, "fail stderr")

-- --- pretty json ---
eq(client.pretty_json('{"a":1,"b":[1,2]}'), '{\n  "a": 1,\n  "b": [\n    1,\n    2\n  ]\n}', "pretty")
eq(client.pretty_json("not json"), nil, "invalid json")

if failed == 0 then
	print("ALL UNIT TESTS PASSED")
else
	print(failed .. " FAILURES")
	os.exit(1)
end
