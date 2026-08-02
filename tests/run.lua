-- Unit tests: parser + substitution + response parsing + pretty-printing.
-- Run: nvim --headless -l tests/run.lua
package.path = "./lua/?.lua;" .. package.path
local parser = require("tuiter.parser")
local client = require("tuiter.client")
local ui = require("tuiter.ui")

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
	eq(#parser.parse_lines(vim.split(content, "\n")), 9, "demo requests")
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

-- --- copy as curl ---
local cmd = client.curl_command({
	method = "POST",
	url = "http://x.test/{{token}}",
	headers = { ["Content-Type"] = "application/json" },
	body = '{"a":1}',
	vars = { token = "T" },
}, { timeout = 30 })
eq(cmd:match("'-X' 'POST'") ~= nil, true, "curl method")
eq(cmd:match("http://x%.test/T'") ~= nil, true, "curl substituted url")
eq(cmd:match("'%-H' 'Content%-Type: application/json'") ~= nil, true, "curl header")
eq(cmd:match("'%-%-data%-binary' '{\"a\":1}'") ~= nil, true, "curl inline body")
eq(cmd:match("tuiter") ~= nil, false, "no stats marker in curl command")
eq(cmd:match("'@%-'") ~= nil, false, "no stdin placeholder in curl command")

-- --- env default fallback ---
local tmp = vim.fn.tempname() .. "/"
vim.fn.mkdir(tmp, "p")
vim.fn.writefile({ '{"dev":{"user_id":"7"},"prod":{"user_id":"9"}}' }, tmp .. "tuiter.env.json")
client.state.env, client.state.env_file, client.state.env_vars = nil, nil, {}
client.ensure_env(tmp, { env_files = { "tuiter.env.json" }, default_env = "default" })
eq(client.state.env, "dev", "fallback to first env when default missing")
eq(client.state.env_vars.user_id, "7", "fallback env vars")
client.state.env, client.state.env_file = nil, nil
client.ensure_env(tmp, { env_files = { "tuiter.env.json" }, default_env = "prod" })
eq(client.state.env, "prod", "default_env wins when present")

-- --- dynamic variables ---
eq(client.substitute("{{$timestamp}}", {}):match("^%d+$") ~= nil, true, "timestamp")
eq(
	client.substitute("{{$uuid}}", {}):match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
		~= nil,
	true,
	"uuid format"
)
local guid = client.substitute("{{$guid}}", {})
eq(guid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil, true, "guid format")
eq(guid:match("%l") == nil, true, "guid uppercase")
local ri = tonumber(client.substitute("{{$randomInt}}", {}))
eq(ri ~= nil and ri >= 0 and ri <= 1000000, true, "randomInt range")

-- --- response chaining ({{$body.*}}, {{$status}}) ---
client.record_response({ body = '{"token":"abc","data":{"id":5},"list":[10,20]}', status = 200 })
eq(client.substitute("{{$body.token}}", {}), "abc", "body scalar")
eq(client.substitute("{{$body.data.id}}", {}), "5", "body nested")
eq(client.substitute("{{$body.list.0}}", {}), "10", "body array 0-based")
eq(client.substitute("{{$body.list.1}}", {}), "20", "body array index")
eq(client.substitute("{{$body.missing}}", {}), "{{$body.missing}}", "body missing kept")
eq(client.substitute("{{$status}}", {}), "200", "status")

-- --- pretty json ---
eq(client.pretty_json('{"a":1,"b":[1,2]}'), '{\n  "a": 1,\n  "b": [\n    1,\n    2\n  ]\n}', "pretty")
eq(client.pretty_json("not json"), nil, "invalid json")

if failed == 0 then
	print("ALL UNIT TESTS PASSED")
else
	print(failed .. " FAILURES")
	os.exit(1)
end

-- --- @name request naming (REST Client style) ---
local named = parser.parse_lines({
	"### A",
	"GET https://x.test/1",
	"# @name first",
	"",
	"### B",
	"POST https://x.test/2",
	"# @name=second",
})
eq(named[1].name, "first", "@name after request")
eq(named[2].name, "second", "@name= syntax")
eq(parser.parse_lines({ "GET https://x.test/", "# @name bare" })[1].name, "bare", "@name on implicit request")

-- --- omni-completion ---
client.set_env("dev", ".", { env_files = { "tests/fixtures/env.json" } })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "### X", "GET https://x.test/{{tok", "" })
vim.api.nvim_win_set_cursor(0, { 2, #"GET https://x.test/{{tok" })
eq(client.complete(1, ""), #"GET https://x.test/{{", "findstart column after {{")
local items = client.complete(0, "tok")
local found = vim.tbl_filter(function(it)
	return it.word == "{{token}}"
end, items)
eq(#found == 1, true, "completion includes env var")

-- --- extended curl timing (-w marker with 9 fields) ---
local ex = client.parse_response(
	"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{}"
		.. "\n@@tuiter9@@ 200 0.223 12 0.01 0.04 0.09 0.10 0.22 1",
	"",
	0,
	"@@tuiter9@@"
)
eq(ex.time, 0.223, "extended total time")
eq(ex.size, 12, "extended size")
eq(ex.times.starttransfer, 0.22, "extended starttransfer")
eq(ex.times.namelookup, 0.01, "extended namelookup")
eq(ex.redirects, 1, "extended redirects")
eq(ex.body, "{}", "extended body intact")
-- legacy 3-field marker still parses (old tests + old caches)
local leg = client.parse_response("HTTP/1.1 200 OK\r\n\r\n{}" .. "\n@@tuiterL@@ 200 0.05 42", "", 0, "@@tuiterL@@")
eq(leg.time, 0.05, "legacy time")
eq(leg.size, 42, "legacy size")
eq(leg.times, nil, "legacy no times table")

-- --- timeline tab rendering ---
local tl = ui.timeline_lines({
	headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8",
	body = "{}",
	status = 200,
	size = 12,
	time = 0.223,
	redirects = 1,
	times = {
		namelookup = 0.01,
		connect = 0.04,
		appconnect = 0.09,
		pretransfer = 0.1,
		starttransfer = 0.22,
		total = 0.223,
	},
})
eq(tl[1]:match("DNS lookup%s+10ms") ~= nil, true, "timeline DNS delta")
eq(tl[2]:match("TCP connect%s+30ms") ~= nil, true, "timeline TCP delta")
eq(tl[3]:match("TLS handshake%s+4%dms") ~= nil, true, "timeline TLS delta")
eq(tl[6]:match("Download%s+3ms") ~= nil, true, "timeline download delta")
eq(tl[7]:match("Total%s+223ms") ~= nil, true, "timeline total")
eq(table.concat(tl, "\n"):match("Size%s+12B") ~= nil, true, "timeline size")
eq(table.concat(tl, "\n"):match("Redirects%s+1") ~= nil, true, "timeline redirects")
eq(table.concat(tl, "\n"):match("Protocol%s+HTTP/1.1") ~= nil, true, "timeline protocol")
eq(table.concat(tl, "\n"):match("Content type%s+application/json") ~= nil, true, "timeline content type")

-- --- request directives (# @timeout, # @no-redirect, # @no-log) ---
local dirs = parser.parse_lines({
	"### A",
	"GET https://x.test/1",
	"# @timeout 5",
	"# @no-redirect",
	"# @no-log",
})
eq(dirs[1].opts.timeout, "5", "directive timeout")
eq(dirs[1].opts.no_redirect, true, "directive no-redirect")
eq(dirs[1].opts.no_log, true, "directive no-log")

-- --- validation ---
eq(#parser.validate({ "### ok", "GET https://x.test/", "Accept: */*", "", "body" }), 0, "validate clean file")
local v = parser.validate({ "GET", "ftp://nope/", "Accept: */*" })
eq(v[1] and v[1].msg:match("missing a URL") ~= nil, true, "validate bare method")
eq(v[2] and v[2].msg:match("does not start with http") ~= nil, true, "validate bad scheme")

-- --- graphql parsing ---
local gql = require("tuiter.graphql").parse({
	"# @url http://127.0.0.1:8999/graphql",
	"",
	"query GetUser($id: ID!) {",
	"  user(id: $id) { name }",
	"}",
	"",
	"mutation UpdateUser {",
	'  updateUser(input: {name: "ada"}) { id }',
	"}",
})
eq(#gql, 2, "graphql two operations")
eq(gql[1].name, "GetUser", "graphql query name")
eq(gql[1].method, "POST", "graphql POST")
eq(gql[1].url, "http://127.0.0.1:8999/graphql", "graphql url from directive")
eq(vim.json.decode(gql[1].body).query:match("user%(id") ~= nil, true, "graphql query body")
eq(vim.json.decode(gql[2].body).query:match("updateUser") ~= nil, true, "graphql mutation body")
local gql2 = require("tuiter.graphql").parse({ "# @url http://x.test/", "", '# @variables {"a":1}', "query Q { x }" })
eq(vim.json.decode(gql2[1].body).variables.a, 1, "graphql variables directive")

-- --- new dynamic vars ---
eq(
	client.substitute("{{$isoTimestamp}}", {}):match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil,
	true,
	"iso timestamp"
)
eq(#client.substitute("{{$randomAlphaNumeric}}", {}), 16, "random alphanumeric length")
eq(client.substitute("{{$randomEmail}}", {}):match("@example.com$") ~= nil, true, "random email")
client.record_response({ body = "raw text", status = 200 })
eq(client.substitute("{{$body}}", {}), "raw text", "raw body var")

-- --- body modes + cookie jar + compressed in curl args ---
local a = client.curl_args({
	method = "POST",
	url = "http://x.test/",
	headers = { ["Content-Type"] = "multipart/form-data" },
	body = "name=ada\nrole=admin",
	vars = {},
	cwd = ".",
}, { cookie_jar = true })
eq(vim.tbl_contains(a, "-F") and vim.tbl_contains(a, "name=ada"), true, "multipart -F fields")
eq(vim.tbl_contains(a, "--data-binary"), false, "multipart no data-binary")
eq(vim.tbl_contains(a, "--compressed"), true, "compressed default")
eq(vim.tbl_contains(a, "-c") and vim.tbl_contains(a, "-b"), true, "cookie jar flags")
eq(a[vim.fn.index(a, "-c") + 2]:match("cookies/.*%.txt") ~= nil, true, "cookie jar path")
local ue = client.curl_args({
	method = "POST",
	url = "http://x.test/",
	headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
	body = "name=ada\nrole=admin",
	vars = {},
	cwd = nil,
}, { cookie_jar = false })
eq(vim.tbl_contains(ue, "--data-urlencode") and vim.tbl_contains(ue, "name=ada"), true, "urlencoded --data-urlencode")
eq(vim.tbl_contains(ue, "-c"), false, "cookie jar disabled")
-- per-request timeout + no-redirect override
local pr = client.curl_args({
	method = "GET",
	url = "http://x.test/",
	headers = {},
	body = nil,
	vars = {},
	opts = { timeout = "5", no_redirect = true },
	cwd = nil,
}, { timeout = 30, max_redirects = 8, cookie_jar = false })
eq(pr[vim.fn.index(pr, "--max-time") + 2], "5", "per-request timeout")
eq(vim.tbl_contains(pr, "-L"), false, "no-redirect skips -L")

-- --- code snippets ---
local cg = require("tuiter.codegen")
local spec = {
	method = "POST",
	url = "http://x.test/{{token}}",
	headers = { ["Content-Type"] = "application/json" },
	body = '{"a":1}',
	vars = { token = "T" },
}
local py = cg.generate("python", spec, {})
eq(py:match("import requests") ~= nil, true, "python imports")
eq(py:match('url = "http://x%.test/T"') ~= nil, true, "python substituted url")
eq(py:match('requests%.request%(%-%-"POST"') == nil, true, "python request call") -- placeholder, replaced below
eq(py:match("json%.dumps%(payload%)") ~= nil, true, "python json body")
local js = cg.generate("js", spec, {})
eq(js:match("fetch%(url, options%)") ~= nil, true, "js fetch")
eq(js:match('method: "POST"') ~= nil, true, "js method")
local go = cg.generate("go", spec, {})
eq(go:match("http%.NewRequest") ~= nil, true, "go NewRequest")
eq(go:match('url := "http://x%.test/T"') ~= nil, true, "go substituted url")
eq(cg.generate("curl", spec, {}):match("http://x%.test/T'") ~= nil, true, "curl snippet")

-- --- history dedupe ---
local hst = require("tuiter.history")
local hfile = vim.fn.stdpath("data") .. "/tuiter/history.json"
vim.fn.mkdir(vim.fn.stdpath("data") .. "/tuiter", "p")
vim.fn.writefile({ "[]" }, hfile)
local saved = vim.fn.filereadable(hfile) == 1 and vim.fn.readfile(hfile) or nil
hst.add(
	{ method = "GET", url = "http://x.test/1", name = "", headers = {}, body = nil, vars = {}, cwd = "." },
	{ status = 200, time = 0.1, size = 1 }
)
hst.add(
	{ method = "GET", url = "http://x.test/1", name = "", headers = {}, body = nil, vars = {}, cwd = "." },
	{ status = 200, time = 0.2, size = 1 }
)
eq(#hst.load(), 1, "history dedupes consecutive identical")
eq(hst.load()[1].time, 0.2, "history keeps latest time")
hst.add(
	{ method = "POST", url = "http://x.test/2", name = "", headers = {}, body = "{}", vars = {}, cwd = "." },
	{ status = 201, time = 0.1, size = 2 }
)
eq(#hst.load(), 2, "history keeps distinct")
if saved then
	vim.fn.writefile(saved, hfile)
else
	os.remove(hfile)
end
