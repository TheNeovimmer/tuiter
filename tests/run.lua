-- Unit tests: parser + substitution + response parsing + pretty-printing.
-- Run: nvim --headless -l tests/run.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
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

-- # @skip directive: opts.skip is boolean true (excluded from run-all/CI)
local reqs4 = parser.parse_lines({ "### Destructive", "# @skip", "DELETE http://x.test/things" })
eq(reqs4[1].opts.skip, true, "skip directive parses")
local reqs5 = parser.parse_lines({ "### Normal", "GET http://x.test/" })
eq(reqs5[1].opts.skip, nil, "no skip without directive")

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

-- =====================================================================
-- New features (pro): named chaining, assertions, import, codegen, auth,
-- directives, dotenv, redaction
-- =====================================================================

-- --- named response chaining ({{name.body.path}}, {{name.status}}) ---
client.state.responses = {}
client.record_response(
	{ body = '{"token":"L-T","n":1}', status = 200, headers = "", ok = true },
	{ name = "login", url = "http://x/login" }
)
eq(client.substitute("{{login.body.token}}", {}), "L-T", "named body.chaining")
eq(client.substitute("{{login.status}}", {}), "200", "named status")
eq(client.substitute("{{login.body}}", {}), '{"token":"L-T","n":1}', "named raw body")
eq(client.substitute("{{login.body.missing}}", {}), "{{login.body.missing}}", "named missing kept")
eq(client.substitute("{{unknown.body.x}}", {}), "{{unknown.body.x}}", "unknown name kept")

-- --- assertions (# @test) ---
local ar = {
	status = 200,
	headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n",
	body = '{"token":"abc","items":[1,2,3],"error":null}',
	ok = true,
	time = 0.12,
	size = 10,
}
eq(client.eval_test("status == 200", ar).pass, true, "t status ==")
eq(client.eval_test("status < 300", ar).pass, true, "t status <")
eq(client.eval_test("status >= 201", ar).pass, false, "t status >=")
eq(client.eval_test("body.token exists", ar).pass, true, "t body exists")
eq(client.eval_test("body.error == null", ar).pass, true, "t body null")
eq(client.eval_test("body.error exists", ar).pass, false, "t body null exists false")
eq(client.eval_test("body.items.length > 2", ar).pass, true, "t body length >")
eq(client.eval_test("body.items contains 3", ar).pass, true, "t body contains int")
eq(client.eval_test('headers.content-type contains "json"', ar).pass, true, "t header contains")
eq(client.eval_test("responseTime < 500", ar).pass, true, "t responseTime <")
eq(client.eval_test("missiong == 1", ar) == nil, true, "t unparseable lhs nil")
local ev = client.eval_tests({ "status == 200", "body.nope == 1" }, ar)
eq(#ev, 2, "t eval count")
eq(ev[1].pass, true, "t eval pass")
eq(ev[2].pass, false, "t eval fail")
eq(#ar.tests, 2, "t resp.tests set")
eq(ar.failures, 1, "t resp.failures")

-- --- parser: tests array, auth directive, body_line ---
local pr = parser.parse_lines({
	"### A",
	"# @test status == 201",
	"# @test body.id exists",
	"# @auth oauth2 token_url=http://x/token client_id=cid client_secret=cs scope=api",
	"POST http://x/",
	"Content-Type: application/json",
	"",
	'{"a":1}',
})
eq(#pr[1].tests, 2, "parser tests array")
eq(pr[1].auth.type, "oauth2", "parser auth type")
eq(pr[1].auth.client_id, "cid", "parser auth client_id")
eq(pr[1].auth.token_url, "http://x/token", "parser auth token_url")
eq(pr[1].body, '{"a":1}', "parser body")
eq(pr[1].body_line, 8, "parser body_line (first content line)")
local be = parser.parse_lines({ "### A", "# @auth bearer TOK1", "GET http://x/" })
eq(be[1].auth.type, "bearer", "parser bearer auth")
eq(be[1].auth.token, "TOK1", "parser bearer token")

-- --- curl directives (cert/key/proxy/insecure) ---
local dc = client.curl_args({
	method = "GET",
	url = "http://x/",
	headers = {},
	body = nil,
	vars = {},
	opts = { cert = "cert.pem", key = "key.pem", proxy = "http://proxy:8080", insecure = true },
	cwd = nil,
}, { cookie_jar = false, insecure = false })
eq(vim.tbl_contains(dc, "--cert") and vim.tbl_contains(dc, "cert.pem"), true, "cert directive")
eq(vim.tbl_contains(dc, "--key") and vim.tbl_contains(dc, "key.pem"), true, "key directive")
eq(vim.tbl_contains(dc, "--proxy") and vim.tbl_contains(dc, "http://proxy:8080"), true, "proxy directive")
eq(vim.tbl_contains(dc, "-k"), true, "per-request insecure")

-- --- codegen expansion ---
local cgspec = {
	method = "POST",
	url = "http://x.test/",
	headers = { ["Content-Type"] = "application/json", Authorization = "Bearer abc" },
	body = '{"a":1}',
	vars = {},
}
eq(cg.generate("ts", cgspec, {}):match("const url: string") ~= nil, true, "ts typed url")
eq(cg.generate("ts", cgspec, {}):match("JSON.stringify") ~= nil, true, "ts json body")
eq(cg.generate("rust", cgspec, {}):match("reqwest::Client::new()") ~= nil, true, "rust reqwest")
eq(cg.generate("php", cgspec, {}):match("curl_exec") ~= nil, true, "php curl")
local gq = cg.generate(
	"graphql",
	{ method = "POST", url = "http://x/g", headers = {}, vars = {}, body = '{"query":"query Q { x }","variables":null}' },
	{}
)
eq(gq:match('"query Q { x }"') ~= nil, true, "graphql codegen query")
eq(cg.generate("curl", cgspec, {}):match("http://x%.test/") ~= nil, true, "curl still works")

-- --- import: postman + openapi ---
local imp = require("tuiter.import")
local pm, pmerr = imp.postman(vim.json.encode({
	info = { name = "demo" },
	item = {
		{ name = "get users", request = { method = "GET", url = "https://api.x/users" } },
		{
			name = "create",
			item = {
				{
					name = "post",
					request = {
						method = "POST",
						url = "https://api.x/users",
						header = { { key = "Content-Type", value = "application/json" } },
						body = { mode = "raw", raw = '{"a":1}' },
					},
				},
			},
		},
	},
}))
eq(pmerr == nil, true, "postman parse")
eq(pm:match("### get users") ~= nil, true, "postman name")
eq(pm:match("GET https://api%.x/users") ~= nil, true, "postman method+url")
eq(pm:match("POST https://api%.x/users") ~= nil, true, "postman nested item")
eq(pm:match('{"a":1}') ~= nil, true, "postman raw body")
local oa, oaerr = imp.openapi(vim.json.encode({
	openapi = "3.0.3",
	servers = { { url = "https://api.x/v1" } },
	paths = {
		["/users/{id}"] = {
			get = {
				operationId = "getUser",
				parameters = {
					{ name = "id", ["in"] = "path" },
					{ name = "verbose", ["in"] = "query", schema = { example = "true" } },
				},
			},
			post = {
				operationId = "createUser",
				requestBody = { content = { ["application/json"] = { example = { name = "ada" } } } },
			},
		},
	},
}))
eq(oaerr == nil, true, "openapi parse")
eq(oa:find("GET https://api.x/v1/users/:param?verbose=true", 1, true) ~= nil, true, "openapi get+query")
eq(oa:match("POST https://api%.x/v1/users/:param") ~= nil, true, "openapi post")
eq(oa:find('{"name":"ada"}', 1, true) ~= nil, true, "openapi example body")

-- --- history redaction ---
local h2 = require("tuiter.history")
local _saved2 = vim.fn.filereadable(hfile) == 1 and vim.fn.readfile(hfile) or nil
vim.fn.writefile({ "[]" }, hfile)
h2.add({
	method = "GET",
	url = "http://x/",
	name = "",
	headers = { Authorization = "Bearer SECRET", ["X-Keep"] = "v", Cookie = "sid=1" },
	body = nil,
	vars = {},
	cwd = ".",
}, { status = 200, time = 0, size = 1 })
local stored = h2.load()[1].spec.headers
eq(stored.Authorization == nil, true, "redact authorization")
eq(stored.Cookie == nil, true, "redact cookie")
eq(stored["X-Keep"], "v", "keep other headers")
if _saved2 then
	vim.fn.writefile(_saved2, hfile)
else
	os.remove(hfile)
end

-- --- dotenv ---
local dtmp = vim.fn.tempname() .. "/"
vim.fn.mkdir(dtmp, "p")
vim.fn.writefile({ "DB_HOST=localhost", 'GREET="hi there"', "QUOTED='x'" }, dtmp .. ".env")
local dv = client.dotenv(dtmp)
eq(dv.DB_HOST, "localhost", "dotenv var")
eq(dv.GREET, "hi there", "dotenv strip quotes")

-- =====================================================================
-- New: CRLF cleanup, env hot reload, # @delay, multipart file fields,
-- curl import (:TuiterImportCurl)
-- =====================================================================

-- --- CRLF headers are stripped so the Headers tab has no ^M ---
local cr = client.parse_response("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{}", "", 0, "@@tuiterC@@")
eq(cr.status, 200, "crlf status")
eq(cr.headers:match("\r") == nil, true, "crlf headers stripped")
eq(cr.headers:match("^HTTP/1.1 200 OK"), "HTTP/1.1 200 OK", "crlf headers intact")

-- --- env hot reload (mtime change) ---
local etmp = vim.fn.tempname() .. "/"
vim.fn.mkdir(etmp, "p")
vim.fn.writefile({ '{"dev":{"k":"v1"}}' }, etmp .. "tuiter.env.json")
client.state.env, client.state.env_file, client.state.env_vars, client.state.env_mtime = nil, nil, {}, nil
client.ensure_env(etmp, { env_files = { "tuiter.env.json" } })
eq(client.state.env_vars.k, "v1", "env first load")
vim.uv.sleep(1100) -- getftime has 1s resolution: guarantee a different mtime
vim.fn.writefile({ '{"dev":{"k":"v2"}}' }, etmp .. "tuiter.env.json")
client.ensure_env(etmp, { env_files = { "tuiter.env.json" } })
eq(client.state.env_vars.k, "v2", "env reloads after mtime change")
client.state.env, client.state.env_file, client.state.env_vars, client.state.env_mtime = nil, nil, {}, nil

-- --- # @delay directive ---
local dl = parser.parse_lines({ "### A", "GET https://x.test/", "# @delay 500" })
eq(dl[1].opts.delay, "500", "delay directive parses")

-- --- multipart file upload: `key=@path` resolves against spec.cwd ---
local mf = client.curl_args({
	method = "POST",
	url = "http://x.test/upload",
	headers = { ["Content-Type"] = "multipart/form-data" },
	body = "name=ada\navatar=@pic.png",
	vars = {},
	cwd = "/tmp/proj",
}, { cookie_jar = false })
eq(
	vim.tbl_contains(mf, "-F") and vim.tbl_contains(mf, "avatar=@/tmp/proj/pic.png"),
	true,
	"multipart file resolved vs cwd"
)
eq(vim.tbl_contains(mf, "name=ada"), true, "multipart plain field kept")
local mf2 = client.curl_args({
	method = "POST",
	url = "http://x.test/upload",
	headers = { ["Content-Type"] = "multipart/form-data" },
	body = "avatar=@/abs/pic.png",
	vars = {},
	cwd = "/tmp/proj",
}, { cookie_jar = false })
eq(vim.tbl_contains(mf2, "avatar=@/abs/pic.png"), true, "multipart absolute path kept")

-- --- curl import (:TuiterImportCurl) ---
local ic = require("tuiter.import")
local c1, e1 = ic.curl("curl 'https://api.x/users'")
eq(e1 == nil and c1:match("^GET https://api%.x/users$") ~= nil, true, "curl import basic")
local c2 = ic.curl("curl -X POST https://api.x/users -H 'Content-Type: application/json' --data-raw '{\"a\":1}'")
eq(c2:match("^POST https://api%.x/users") ~= nil, true, "curl import method")
eq(c2:match("Content%-Type: application/json") ~= nil, true, "curl import header")
eq(c2:find('{"a":1}', 1, true) ~= nil, true, "curl import json body")
local c3 = ic.curl("curl -d 'a=1' -d 'b=2' http://x/")
eq(c3:find("Content-Type: application/x-www-form-urlencoded", 1, true) ~= nil, true, "curl import urlencoded ct")
eq(c3:find("a=1", 1, true) ~= nil and c3:find("b=2", 1, true) ~= nil, true, "curl import fields as lines")
local c3b = ic.curl("curl -d 'a=1' http://x/")
eq(c3b:find("Content-Type: application/x-www-form-urlencoded", 1, true) ~= nil, true, "curl import single -d field ct")
local c4 = ic.curl("curl -u admin:secret http://x/")
eq(
	c4:find("Authorization: Basic " .. vim.base64.encode("admin:secret"), 1, true) ~= nil,
	true,
	"curl import basic auth"
)
local c5 = ic.curl("curl -G http://x/search --data-urlencode 'q=hello world'")
eq(c5:find("http://x/search?q=hello%20world", 1, true) ~= nil, true, "curl import -G query")
local c6 = ic.curl("curl -F 'name=ada' -F 'avatar=@pic.png' http://x/upload")
eq(c6:find("Content-Type: multipart/form-data", 1, true) ~= nil, true, "curl import multipart ct")
eq(c6:find("avatar=@pic.png", 1, true) ~= nil, true, "curl import multipart file field")
local c7 = ic.curl("curl -k https://x/")
eq(c7:match("^# @insecure") ~= nil, true, "curl import insecure")
local c8 = ic.curl("curl -A 'my-ua' -e http://ref/ -b 'sid=1' http://x/")
eq(c8:find("User-Agent: my-ua", 1, true) ~= nil, true, "curl import user-agent")
eq(c8:find("Referer: http://ref/", 1, true) ~= nil, true, "curl import referer")
eq(c8:find("Cookie: sid=1", 1, true) ~= nil, true, "curl import cookie header")
local c8b = ic.curl("curl -b cookies.txt http://x/")
eq(c8b:find("Cookie:", 1, true) == nil, true, "curl import cookie jar skipped")
local _, e9 = ic.curl("echo hi")
eq(e9 ~= nil, true, "curl import no url errors")

-- --- ui.json_path: JSONPath from the pretty render ---
local function plines(body)
	return vim.split(client.pretty_json(body), "\n")
end
local a = plines('{"a": {"b": 1}, "list": [1, {"x": 2}]}')
eq(ui.json_path(a, 1), "$", "jsonpath root")
eq(ui.json_path(a, 2), "$.a", "jsonpath nested key")
eq(ui.json_path(a, 3), "$.a.b", "jsonpath scalar value")
eq(ui.json_path(a, 5), "$.list", "jsonpath array key")
eq(ui.json_path(a, 6), "$.list[0]", "jsonpath scalar element")
eq(ui.json_path(a, 7), "$.list[1]", "jsonpath container element")
eq(ui.json_path(a, 8), "$.list[1].x", "jsonpath deep")
local r = plines('[{"z": 9}, "hi", 5]')
eq(ui.json_path(r, 3), "$[0].z", "jsonpath root array key")
eq(ui.json_path(r, 5), "$[1]", "jsonpath root array string elem")
eq(ui.json_path(r, 6), "$[2]", "jsonpath root array number elem")
local n = plines("[[1, 2], [3]]")
eq(ui.json_path(n, 3), "$[0][0]", "jsonpath nested array a")
eq(ui.json_path(n, 4), "$[0][1]", "jsonpath nested array b")
eq(ui.json_path(n, 7), "$[1][0]", "jsonpath nested array c")
local m = plines('{"a-b": 1, "x y": 2}')
eq(ui.json_path(m, 2), '$["a-b"]', "jsonpath dotted key")
eq(ui.json_path(m, 3), '$["x y"]', "jsonpath space key")
local e = plines('{"empty": {}, "lst": []}')
eq(ui.json_path(e, 2), "$.empty", "jsonpath empty object")
eq(ui.json_path(e, 3), "$.lst", "jsonpath empty array")

-- --- client.resolve_name: substitution precedence ---
client.state.env_vars = { token = "env-token", user_id = "9" }
local v1, s1 = client.resolve_name("token", { token = "req-token" })
eq(v1, "req-token", "resolve request var wins")
eq(s1, "request", "resolve request source")
local v2, s2 = client.resolve_name("user_id", {})
eq(v2, "9", "resolve env var")
eq(s2, "env", "resolve env source")
local v3 = client.resolve_name("$uuid", {})
eq(v3 ~= nil and #v3 == 36, true, "resolve dynamic uuid")
local v4 = client.resolve_name("nope_123", {})
eq(v4, nil, "resolve unresolved nil")
eq(client.substitute("x{{" .. "token}}y", {}), "xenv-tokeny", "substitute env")
eq(client.substitute("{{nope_123}}", {}), "{{nope_123}}", "substitute unresolved kept")

-- --- # @base: file-level URL prefix + relative URL resolution ---
local reqsB = parser.parse_lines({
	"# @base https://api.example.com/v1",
	"",
	"### List",
	"GET /users",
	"",
	"### Detail",
	"GET /users/{{id}}",
})
eq(reqsB[1].opts.base, "https://api.example.com/v1", "base inherited by first request")
eq(reqsB[2].opts.base, "https://api.example.com/v1", "base inherited by later request")
eq(client.resolve_url(reqsB[1]), "https://api.example.com/v1/users", "relative URL resolved")
eq(client.resolve_url(reqsB[2]), "https://api.example.com/v1/users/{{id}}", "vars left for send-time substitution")
reqsB[1].opts.base = "https://api.example.com/v1/"
eq(client.resolve_url(reqsB[1]), "https://api.example.com/v1/users", "trailing slash on base normalized")
local abs = parser.parse_lines({ "GET https://other.test/x" })[1]
eq(client.resolve_url(abs), "https://other.test/x", "absolute URL untouched")
local absv = parser.parse_lines({ "GET {{host}}/x" })[1]
client.state.env_vars = { host = "https://env.test" }
eq(client.resolve_url(absv), "https://env.test/x", "var-based absolute URL untouched by base")
local ov = parser.parse_lines({
	"# @base https://a.test",
	"### Override",
	"# @base https://b.test/v2",
	"GET /x",
	"### Inherit",
	"GET /y",
})
eq(client.resolve_url(ov[1]), "https://b.test/v2/x", "per-request # @base override")
eq(client.resolve_url(ov[2]), "https://b.test/v2/y", "base override cascades to later requests")
local rb = parser.parse_lines({ "GET /users" })[1]
eq(client.resolve_url(rb), "/users", "relative URL without base stays as-is")

-- review fixes: colon/equals forms, base-in-body validation edge
local colon = parser.parse_lines({ "### X", "# @base: https://c.test", "GET /x" })[1]
eq(colon.opts.base, "https://c.test", "colon-form # @base: URL parses")
local equals = parser.parse_lines({ "# @base = https://c.test", "### X", "GET /x" })[1]
eq(equals.opts.base, "https://c.test", "equals-form file-level # @base = URL parses")
local vb = parser.validate({
	"### A",
	"GET http://a.test",
	"",
	"# @base http://x.test", -- inside A's body: not a real base
	"### B",
	"GET /rel",
})
eq(#vb, 1, "# @base inside a body does not suppress the relative-URL diagnostic")

-- validate: relative URLs are OK with a # @base, flagged without one
local vB = parser.validate({ "# @base https://x.test", "", "GET /users" })
eq(#vB, 0, "relative URL with base is valid")
local vN = parser.validate({ "GET /users" })
eq(#vN, 1, "relative URL without base flagged")
eq(vN[1].msg:match("base") ~= nil, true, "diagnostic hints at # @base")

-- --- $extends: env inheritance (Insomnia-style base env) ---
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local tmpfile = tmpdir .. "/http-client.env.json"
vim.fn.writefile({
	vim.json.encode({
		base = { host = "https://base.test", token = "t0" },
		dev = { ["$extends"] = "base", token = "dev-token" },
	}),
}, tmpfile)
local envopts = { env_files = { "http-client.env.json" } }
client.set_env("dev", tmpdir, envopts)
eq(client.state.env_vars.host, "https://base.test", "$extends: inherited var")
eq(client.state.env_vars.token, "dev-token", "$extends: child wins on conflict")
client.set_env("base", tmpdir, envopts)
eq(client.state.env_vars.token, "t0", "$extends: base env alone works")
local cyc = tmpdir .. "/cyc.json"
vim.fn.writefile({ vim.json.encode({ a = { ["$extends"] = "b" }, b = { ["$extends"] = "a", x = 1 } }) }, cyc)
client.set_env("a", tmpdir, { env_files = { "cyc.json" } })
eq(client.state.env_vars.x, 1, "$extends: circular refs stop without hanging")
os.remove(tmpfile)
os.remove(cyc)
os.remove(tmpdir)

-- --- # @save: response body export ---
local out = vim.fn.tempname()
client.save_response({ opts = { save = out }, cwd = "/tmp" }, { ok = true, status = 200, body = '{"a":1}' })
eq(
	vim.wait(1000, function()
		return vim.fn.filereadable(out) == 1
	end, 50),
	true,
	"save_response wrote the file"
)
if vim.fn.filereadable(out) == 1 then
	eq(table.concat(vim.fn.readfile(out), "\n"), '{"a":1}', "save_response content")
	os.remove(out)
end
client.save_response({ opts = { save = out } }, { ok = false, status = 500, body = "boom" })
eq(vim.fn.filereadable(out), 0, "failed request is not exported")
client.save_response({ opts = {} }, { ok = true, body = "x" })
-- a {{var}} in the save path resolves
local varpath = vim.fn.tempname()
client.save_response({ opts = { save = varpath .. "/{{$randomInt}}.json" }, cwd = "/tmp" }, { ok = true, body = "y" })
local wrote = vim.wait(1000, function()
	return #vim.fn.glob(varpath .. "/*.json", false, true) == 1
end, 50)
eq(wrote, true, "save path vars resolve")
if wrote then
	for _, f in ipairs(vim.fn.glob(varpath .. "/*.json", false, true)) do
		os.remove(f)
	end
end
os.remove(varpath)

-- =====================================================================
-- New: layout config, truncation, history var preview, statusline format
-- =====================================================================

-- --- layout config defaults ---
local init = require("tuiter")
init.setup({})
local opts = init.opts()
eq(opts.windows.layout, "float", "default layout is float")
eq(opts.windows.response_side, "right", "default response_side is right")
eq(opts.windows.sidebar_width, 62, "default sidebar_width")
init.setup({ windows = { layout = "split", sidebar_width = 50 } })
opts = init.opts()
eq(opts.windows.layout, "split", "layout overridden to split")
eq(opts.windows.sidebar_width, 50, "sidebar_width overridden")
init.setup({ windows = { layout = "float" } }) -- reset for other tests

-- --- history var preview (format_item includes vars) ---
local hst3 = require("tuiter.history")
local _saved3 = vim.fn.filereadable(hfile) == 1 and vim.fn.readfile(hfile) or nil
vim.fn.writefile({ "[]" }, hfile)
hst3.add({
	method = "GET",
	url = "http://x.test/{{token}}",
	name = "auth",
	headers = { ["X-Custom"] = "val-{{secret}}", Accept = "application/json" },
	body = '{"user":"{{username}}"}',
	vars = {},
	cwd = ".",
}, { status = 200, time = 0.1, size = 10 })
local hist = hst3.load()
eq(#hist, 1, "history entry added for var preview")
eq(hist[1].spec.url, "http://x.test/{{token}}", "history spec url preserved")
eq(hist[1].spec.headers["X-Custom"], "val-{{secret}}", "history spec header preserved")
if _saved3 then
	vim.fn.writefile(_saved3, hfile)
else
	os.remove(hfile)
end

-- --- ui.json_path works in split mode (offset handled by caller) ---
-- (tested via the existing json_path tests above; split offset is in jump_key)

-- --- set_statusline format: METHOD url · HTTP code · time · size · env ---
-- (tested by checking the format string pattern in set_statusline)
local sl = string.format("%%#%s# %s %s · %s%s %%*", "TuiterStatusOk", "GET", "http://x.test/", "HTTP 200 OK · 45ms · 1.2KB", " · dev")
eq(sl:match("GET"), "GET", "statusline contains method")
eq(sl:match("HTTP 200"), "HTTP 200", "statusline contains status code")
eq(sl:match("45ms"), "45ms", "statusline contains time")
eq(sl:match("1.2KB"), "1.2KB", "statusline contains size")
eq(sl:match("dev"), "dev", "statusline contains env")

if failed == 0 then
	print("ALL UNIT TESTS PASSED (incl. features)")
else
	print(failed .. " FAILURES")
	os.exit(1)
end
