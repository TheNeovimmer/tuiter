--- HTTP client: env/var resolution + curl dispatch + response parsing.
local M = {
	state = {
		env = nil,
		env_file = nil,
		env_mtime = nil, -- mtime of the loaded env file (hot reload)
		env_vars = {},
		response = nil, -- last response (for {{$body.*}} / {{$status}})
		responses = {}, -- name -> response, for named chaining {{name.body.x}}
		procs = {}, -- in-flight vim.system jobs (url or nothing -> job)
	},
}

local seq = 0

math.randomseed(os.time())

local cookie_dir = vim.fn.stdpath("data") .. "/tuiter/cookies"
pcall(vim.fn.mkdir, cookie_dir, "p")

--- Per-project cookie jar (Insomnia-style session persistence).
-- Pure-Lua FNV-1a hash of the cwd: vim.fn.sha256 is illegal inside
-- vim.system callbacks (fast-event context), and the cookies dir is
-- created once at module load for the same reason.
local function jar_path(cwd)
	local h = 2166136261
	for i = 1, #cwd do
		h = bit.bxor(h, cwd:byte(i))
		h = bit.band(h * 16777619, 0xFFFFFFFF)
	end
	return cookie_dir .. "/" .. string.format("%08x", h) .. ".txt"
end

--- Walk up from `dir` looking for the first existing env file.
--- Also checks for collection.env.json in the collection directory.
local function env_file_for(dir, opts)
	local d = dir
	local prev = nil
	while d and d ~= prev do
		-- Check for collection.env.json first
		local collections = require("tuiter.collections")
		local collection_root = collections.find_collection(d)
		if collection_root then
			local collection_env = collections.env_file(collection_root)
			if vim.fn.filereadable(collection_env) == 1 then
				return collection_env
			end
		end
		-- Check standard env files
		for _, f in ipairs(opts.env_files or {}) do
			local p = d .. "/" .. f
			if vim.fn.filereadable(p) == 1 then
				return p
			end
		end
		prev = d
		d = vim.fn.fnamemodify(d, ":h")
	end
	return nil
end

local function read_env_file(path)
	local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
	if not ok or type(decoded) ~= "table" then
		return {}
	end
	return decoded
end

--- Names of all environments found for `dir` (empty when no env file exists).
function M.envs(dir, opts)
	local path = env_file_for(dir, opts)
	if not path then
		return {}
	end
	local names = vim.tbl_keys(read_env_file(path))
	table.sort(names)
	return names
end

--- Merge an env with its `$extends` base env (cycle-safe). dev/staging/prod
--- inherit shared vars from a base env; the child wins on conflicts.
---   { "base": { "host": "https://api.example.com" },
---     "dev":  { "$extends": "base", "token": "dev-token" } }
local function env_with_base(name, envs, seen)
	if type(envs[name]) ~= "table" then
		return {}
	end
	seen = seen or {}
	if seen[name] then
		return {} -- circular $extends: stop (don't loop forever)
	end
	seen[name] = true
	local out = {}
	local ext = envs[name]["$extends"]
	if type(ext) == "string" and ext ~= name and type(envs[ext]) == "table" then
		for k, v in pairs(env_with_base(ext, envs, seen)) do
			out[k] = v
		end
	end
	for k, v in pairs(envs[name]) do
		if k ~= "$extends" then
			out[k] = v
		end
	end
	return out
end

function M.set_env(name, dir, opts)
	local path = env_file_for(dir, opts)
	local envs = path and read_env_file(path) or {}
	local vars = {}
	-- .env provides the base layer; the selected JSON env wins on conflicts
	for k, v in pairs(M.dotenv(dir)) do
		vars[k] = v
	end
	for k, v in pairs(env_with_base(name, envs)) do
		vars[k] = v
	end
	M.state.env = name
	M.state.env_file = path
	M.state.env_mtime = path and vim.fn.getftime(path) or nil
	M.state.env_vars = vars
end

--- Load the default env the first time a project with an env file is used.
function M.ensure_env(dir, opts)
	local path = env_file_for(dir, opts)
	if not path then
		-- no env JSON: a .env file still gives us vars (as a synthetic env)
		if #vim.tbl_keys(M.dotenv(dir)) > 0 and not (M.state.env == ".env" and M.state.env_file == nil) then
			M.state.env = ".env"
			M.state.env_file = nil
			M.state.env_vars = M.dotenv(dir)
		end
		return
	end
	if M.state.env and M.state.env_file == path then
		-- hot reload: re-read the env file when it changed on disk
		if M.state.env_mtime ~= vim.fn.getftime(path) then
			M.set_env(M.state.env, dir, opts)
		end
		return
	end
	local envs = read_env_file(path)
	local names = vim.tbl_keys(envs)
	table.sort(names)
	local name = M.state.env
	if not name or not envs[name] then
		name = (opts.default_env and envs[opts.default_env] and opts.default_env) or names[1]
	end
	M.set_env(name, dir, opts)
end

--- Encode a JSON value back to its canonical string form, or the raw value.
local function json_or_scalar(v)
	if type(v) == "table" then
		return vim.json.encode(v)
	end
	return tostring(v)
end

--- Dynamic values (Insomnia-style):
---   {{$timestamp}}  unix seconds     {{$isoTimestamp}}  RFC3339 UTC
---   {{$uuid}}       random v4 uuid   {{$guid}}  uppercase uuid
---   {{$randomInt}} 0..10^6           {{$randomAlphaNumeric}} 16 chars
---   {{$randomEmail}}  random email   {{$status}}  last response status
---   {{$body}}  raw last response body
---   {{$body.a.b.0.c}}  value from the last response JSON body (dotted path)
local function dynamic(name)
	if name == "$timestamp" then
		return tostring(os.time())
	elseif name == "$isoTimestamp" then
		return os.date("!%Y-%m-%dT%H:%M:%SZ")
	elseif name == "$uuid" then
		local b = {}
		for i = 1, 16 do
			b[i] = math.random(0, 255)
		end
		b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
		b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
		local f = "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x"
		return f:format(unpack(b))
	elseif name == "$guid" then
		return dynamic("$uuid"):upper()
	elseif name == "$randomInt" then
		return tostring(math.random(0, 1000000))
	elseif name == "$randomAlphaNumeric" then
		local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
		local t = {}
		for i = 1, 16 do
			local r = math.random(1, #chars)
			t[i] = chars:sub(r, r)
		end
		return table.concat(t)
	elseif name == "$randomEmail" then
		local chars = "abcdefghijklmnopqrstuvwxyz"
		local t = {}
		for i = 1, 8 do
			local r = math.random(1, #chars)
			t[i] = chars:sub(r, r)
		end
		return table.concat(t) .. math.random(100, 999) .. "@example.com"
	elseif name == "$status" then
		local r = M.state.response
		return r and tostring(r.status) or "{{$status}}"
	elseif name == "$body" then
		local r = M.state.response
		return r and r.body or "{{$body}}"
	elseif name:sub(1, 6) == "$body." then
		local r = M.state.response
		if not r then
			return "{{" .. name .. "}}"
		end
		local v = M.json_path(r.body, name:sub(7))
		if v == nil then
			return "{{" .. name .. "}}"
		end
		return json_or_scalar(v)
	end
	return nil
end

--- Named response chaining: `{{login.body.token}}`, `{{login.status}}`,
--- `{{login.body}}` — resolves against the stored response of the request
--- named `login` (from `# @name login`). Returns nil when unknown.
local function named_response(name)
	local head = name:match("^([%w_]+)")
	local r = head and M.state.responses[head]
	if not r then
		return nil
	end
	local rest = name:sub(#head + 1)
	if rest == "" then
		return nil -- bare name: nothing to extract
	elseif rest == ".status" then
		return tostring(r.status)
	elseif rest == ".body" then
		return r.body
	elseif rest:sub(1, 6) == ".body." then
		local v = M.json_path(r.body, rest:sub(7))
		if v == nil then
			return nil
		end
		return json_or_scalar(v)
	end
	return nil
end

--- Walk a decoded JSON value by dotted path parts. Array indexes are
--- 0-based (Insomnia-style): `list.0` -> first element.
local function walk(data, parts)
	for _, part in ipairs(parts) do
		if type(data) ~= "table" then
			return nil
		end
		local n = tonumber(part)
		data = data[n and n + 1 or part]
	end
	return data
end

--- Get a dotted path (.a.b.0.c) into a JSON string. Returns the decoded
--- value (nil when the body isn't JSON or the path doesn't resolve).
function M.json_path(body, dotted)
	local ok, data = pcall(vim.json.decode, body)
	if not ok then
		return nil
	end
	local v = walk(data, vim.split(dotted, ".", { plain = true }))
	if v == vim.NIL then
		return nil -- JSON null behaves like a missing value
	end
	return v
end

--- Record the response so later requests can reference it. Stored both as
--- the "last" response ({{$body.*}}, {{$status}}) and keyed by the request
--- name ({url/login.body.token}) for named request chaining.
function M.record_response(resp, spec)
	M.state.response = resp
	if spec then
		if spec.name and spec.name ~= "" then
			M.state.responses[spec.name] = resp
		end
		if spec.url then
			M.state.responses[spec.url] = resp
		end
	end
end

local DYNAMIC_HINTS = {
	"$timestamp",
	"$isoTimestamp",
	"$uuid",
	"$guid",
	"$randomInt",
	"$randomAlphaNumeric",
	"$randomEmail",
	"$status",
	"$body",
	"$body.token",
	"$body.data.id",
}

--- Omnifunc for {{var}} placeholders in .http buffers (insert-mode <C-x><C-o>).
--- Candidates: request vars > current env vars > dynamic values.
function M.complete(findstart, base)
	if findstart == 1 then
		local line = vim.api.nvim_get_current_line()
		local col = vim.api.nvim_win_get_cursor(0)[2]
		local before = line:sub(1, col)
		local s = before:match(".*{{([%w_$%.]*)$")
		if s then
			return col - #s
		end
		return -3
	end
	local items, seen = {}, {}
	local function add(text, kind)
		if not seen[text] then
			seen[text] = true
			items[#items + 1] = { word = "{{" .. text .. "}}", kind = kind, dup = 1 }
		end
	end
	local ok, reqs = pcall(require("tuiter.parser").parse_lines, vim.api.nvim_buf_get_lines(0, 0, -1, false))
	if ok then
		for _, r in ipairs(reqs) do
			for k in pairs(r.vars) do
				add(k, "r")
			end
		end
	end
	for k in pairs(M.state.env_vars) do
		add(k, "e")
	end
	for _, d in ipairs(DYNAMIC_HINTS) do
		add(d, "d")
	end
	return items
end

--- Resolve one {{name}} with the full pipeline: request vars > env vars >
--- os env > dynamic values > named response. Returns (value, source); both
--- nil when unresolved. Single source of truth for substitute() and the
--- vars inspector (ui.vars_float).
function M.resolve_name(name, request_vars)
	if request_vars and request_vars[name] ~= nil then
		return tostring(request_vars[name]), "request"
	end
	local e = M.state.env_vars[name]
	if e ~= nil then
		return tostring(e), "env"
	end
	local o = vim.env[name]
	if o ~= nil then
		return o, "os"
	end
	if name:sub(1, 1) == "$" then
		local d = dynamic(name)
		if d ~= nil then
			return d, "dynamic"
		end
	end
	local nr = named_response(name)
	if nr ~= nil then
		return nr, "response"
	end
	return nil, nil
end

--- Replace {{var}} placeholders. Resolution order: request vars > env vars >
--- os env > dynamic values ({{$...}}). Unresolved names are left untouched so
--- the user sees what's missing.
function M.substitute(str, request_vars)
	if type(str) ~= "string" then
		return str
	end
	return (
		str:gsub("{{([%w_$%.]+)}}", function(name)
			local v = M.resolve_name(name, request_vars)
			if v ~= nil then
				return tostring(v)
			end
			return "{{" .. name .. "}}"
		end)
	)
end

--- The final URL for a spec: a relative URL (`GET /users`) is resolved
--- against the `# @base` prefix (vars substituted), then {{vars}} are
--- replaced. Absolute URLs pass through unchanged. This is the single place
--- a URL leaves tuiter (send, copy-as-curl, code snippets, gx, copy URL).
function M.resolve_url(spec)
	local url = spec.url or ""
	local base = spec.opts and spec.opts.base
	if base and base ~= "" and not url:match("^https?://") and not url:match("^{{") then
		url = M.substitute(base, spec.vars):gsub("/+$", "") .. "/" .. url:gsub("^/+", "")
	end
	return M.substitute(url, spec.vars)
end

-- ---------------------------------------------------------------------------
-- Assertions (# @test) — small evaluator over a response.
--   # @test status == 200
--   # @test status < 500
--   # @test body.token exists
--   # @test body.error == null
--   # @test body.items.length > 3
--   # @test body.items contains "pending"
--   # @test headers.content-type contains "json"
--   # @test responseTime < 500
-- ---------------------------------------------------------------------------

local TEST_OPS = { "==", "!=", ">=", "<=", ">", "<", "contains", "matches", "exists", "missing" }

local function test_lhs(value)
	local kind, rest = value:match("^(%w+)%.?(.*)$")
	if not kind then
		return nil
	end
	if kind == "status" then
		return function(resp)
			return resp.status
		end, rest
	elseif kind == "responseTime" then
		return function(resp)
			return (resp.time or 0) * 1000
		end, rest
	elseif kind == "size" then
		return function(resp)
			return resp.size
		end, rest
	elseif kind == "headers" and rest ~= "" then
		return function(resp)
			for hk, hv in resp.headers:gmatch("([^:\r\n]+):%s*([^\r\n]*)") do
				if hk:lower() == rest:lower() then
					return hv:gsub("^%s+", "")
				end
			end
			return nil
		end,
			""
	elseif kind == "body" and rest == "" then
		return function(resp)
			return resp.body
		end, ""
	elseif kind == "body" and rest ~= "" then
		return function(resp)
			local v = M.json_path(resp.body, rest)
			-- Postman/Bruno-style `.length` on an array/object parent
			local sans = rest:match("^(.*)%.length$")
			if v == nil and sans then
				v = M.json_path(resp.body, sans)
				if type(v) == "table" then
					v = #v
				end
			end
			return v
		end,
			""
	end
	return nil
end

local function test_rhs(value)
	local v = value:gsub("^%s+", ""):gsub("%s+$", "")
	if v == "null" or v == "" then
		return nil
	elseif v == "true" then
		return true
	elseif v == "false" then
		return false
	end
	local q = v:match("^['\"](.*)['\"]$")
	if q then
		return q
	end
	local n = tonumber(v)
	if n then
		return n
	end
	return v
end

local function to_num(v)
	if type(v) == "number" then
		return v
	end
	if type(v) == "string" and tonumber(v) then
		return tonumber(v)
	end
	return nil
end

local function compare(a, b, op)
	local an, bn = to_num(a), to_num(b)
	if op == "==" then
		return an ~= nil and bn ~= nil and an == bn or tostring(a) == tostring(b)
	elseif op == "!=" then
		return not (an ~= nil and bn ~= nil and an == bn or tostring(a) == tostring(b))
	end
	if an == nil or bn == nil then
		return false
	end
	if op == ">" then
		return an > bn
	elseif op == ">=" then
		return an >= bn
	elseif op == "<" then
		return an < bn
	elseif op == "<=" then
		return an <= bn
	end
	return false
end

--- Evaluate a single `# @test` expression against a response.
--- Returns { pass = boolean, actual = string|nil } (nil when unparseable).
function M.eval_test(expr, resp)
	local op
	for _, candidate in ipairs(TEST_OPS) do
		local i = expr:find(candidate, 1, true)
		if i and (op == nil or i < expr:find(op, 1, true)) then
			op = candidate
		end
	end
	if not op then
		return nil
	end
	local at = expr:find(op, 1, true)
	local lhs_s, rhs_s = expr:sub(1, at - 1):gsub("%s+$", ""), expr:sub(at + #op)
	local get, rest = test_lhs(lhs_s)
	if not get then
		return nil
	end
	if op == "exists" or op == "missing" then
		local v = get(resp)
		local present = v ~= nil and v ~= ""
		return { pass = (op == "exists") == present, actual = present and json_or_scalar(v) or nil }
	end
	local lhs = get(resp)
	local rhs = test_rhs(rhs_s)
	if op == "contains" then
		if type(lhs) == "table" then
			-- array membership
			return { pass = vim.tbl_contains(lhs, rhs), actual = lhs }
		end
		local hay = tostring(lhs or "")
		return { pass = hay:find(tostring(rhs), 1, true) ~= nil, actual = lhs }
	elseif op == "matches" then
		local hay = tostring(lhs or "")
		local ok, m = pcall(function()
			return hay:find(rhs) ~= nil
		end)
		return { pass = ok and m, actual = lhs }
	end
	return { pass = compare(lhs, rhs, op), actual = lhs }
end

--- Evaluate a request's assertions; sets resp.tests + resp.failures.
function M.eval_tests(tests, resp)
	local results = {}
	local fails = 0
	for _, expr in ipairs(tests or {}) do
		local r = M.eval_test(expr, resp)
		if not r then
			r = { pass = false, actual = nil, error = "unparseable" }
		end
		r.expr = expr
		results[#results + 1] = r
		if not r.pass then
			fails = fails + 1
		end
	end
	resp.tests = results
	resp.failures = fails
	return results
end

-- ---------------------------------------------------------------------------
-- .env support: KEY=VALUE pairs from the nearest .env above the project dir.
-- ---------------------------------------------------------------------------

--- Load KEY=VALUE pairs from the nearest `.env` above `dir` ({} when none).
function M.dotenv(dir)
	if not dir then
		return {}
	end
	local d = dir
	local prev = nil
	while d and d ~= prev do
		local p = d .. "/.env"
		if vim.fn.filereadable(p) == 1 then
			local vars = {}
			for _, raw in ipairs(vim.fn.readfile(p)) do
				local k, v = raw:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
				if k and v ~= "" then
					vars[k] = v:gsub("^['\"](.*)['\"]$", "%1")
				end
			end
			return vars
		end
		prev = d
		d = vim.fn.fnamemodify(d, ":h")
	end
	return {}
end

--- (internal) env vars from the `.env` file, if any.
function M.dotenv_vars(dir)
	return M.dotenv(dir)
end

--- Parse curl output (built with -i and a trailing write-out marker line).
--- Marker carries: code, total, size, namelookup, connect, appconnect,
--- pretransfer, starttransfer, redirects (the old 3-field format still parses).
function M.parse_response(stdout, stderr, exit_code, marker, signal)
	local killed = signal and signal ~= 0
	local resp = {
		ok = exit_code == 0 and not killed,
		status = 0,
		headers = "",
		body = "",
		error = killed and "request canceled" or stderr,
	}
	local code, t, size, nl, cn, ap, pr, st, red = stdout:match(
		"\n" .. marker .. " (%d+) ([%d%.]+) (%d+) ([%d%.]+) ([%d%.]+) ([%d%.]+) ([%d%.]+) ([%d%.]+) (%d+)\r?\n?$"
	)
	if not code then
		-- legacy 3-field marker
		code, t, size = stdout:match("\n" .. marker .. " (%d+) ([%d%.]+) (%d+)\r?\n?$")
	end
	if code then
		resp.status = tonumber(code)
		resp.time = tonumber(t)
		resp.size = tonumber(size)
		resp.times = nl
				and {
					namelookup = tonumber(nl),
					connect = cn and tonumber(cn),
					appconnect = ap and tonumber(ap),
					pretransfer = pr and tonumber(pr),
					starttransfer = st and tonumber(st),
					total = tonumber(t),
				}
			or nil
		resp.redirects = red and tonumber(red)
		local newpat = "\n" .. marker .. " %d+ [%d%.]+ %d+ [%d%.]+ [%d%.]+ [%d%.]+ [%d%.]+ [%d%.]+ %d+\r?\n?$"
		local oldpat = "\n" .. marker .. " %d+ [%d%.]+ %d+\r?\n?$"
		stdout = stdout:gsub(newpat, ""):gsub(oldpat, "")
	end
	local head, body = stdout:match("^(.-)\r?\n\r?\n(.*)$")
	if head then
		resp.headers, resp.body = head, body
		-- curl -i writes CRLF headers; strip the \r so the Headers tab is clean
		resp.headers = resp.headers:gsub("\r", "")
	else
		resp.body = stdout
	end
	resp.status = resp.status ~= 0 and resp.status or tonumber(resp.headers:match("^HTTP/%S+ (%d+)")) or 0
	return resp
end

--- Build the curl argv for a spec. When `marker` is given, a write-out
--- stats line is appended (used by send; nil for the human "copy as curl").
--- Body modes by Content-Type:
---   multipart/form-data (k=v lines, no explicit boundary)  -> -F fields
---   application/x-www-form-urlencoded (k=v lines, no "&")   -> --data-urlencode
---   anything else                                          -> --data-binary @-
function M.curl_args(spec, curl_opts, marker)
	curl_opts = curl_opts or {}
	local o = spec.opts or {}
	local timeout = tonumber(o.timeout) or curl_opts.timeout or 30
	local args = { "curl", "-sS", "-i", "-X", spec.method, "--max-time", tostring(timeout) }
	if o.insecure or curl_opts.insecure then
		vim.list_extend(args, { "-k" })
	end
	if o.cert then
		vim.list_extend(args, { "--cert", M.substitute(o.cert, spec.vars) })
	end
	if o.key then
		vim.list_extend(args, { "--key", M.substitute(o.key, spec.vars) })
	end
	if o.proxy then
		vim.list_extend(args, { "--proxy", M.substitute(o.proxy, spec.vars) })
	end
	local follow = not o.no_redirect
	if follow and curl_opts.max_redirects and curl_opts.max_redirects > 0 then
		vim.list_extend(args, { "-L", "--max-redirs", tostring(curl_opts.max_redirects) })
	end
	if curl_opts.compressed ~= false then
		vim.list_extend(args, { "--compressed" })
	end
	if curl_opts.cookie_jar ~= false and spec.cwd then
		local jar = jar_path(spec.cwd)
		vim.list_extend(args, { "-c", jar, "-b", jar })
	end

	local body = spec.body and M.substitute(spec.body, spec.vars) or nil
	local mode = "raw"
	if body and body ~= "" then
		local ct = ""
		for k, v in pairs(spec.headers or {}) do
			if k:lower() == "content-type" then
				ct = (v or ""):lower()
			end
		end
		if ct:match("multipart/form%-data") and not body:match("^%s*%-%-") then
			mode = "multipart"
		elseif ct:match("application/x%-www%-form%-urlencoded") and not body:match("&") and body:match("=") then
			mode = "urlencoded"
		end
	end

	local headers = {}
	for k, v in pairs(spec.headers or {}) do
		-- curl builds its own Content-Type (with boundary) for -F fields
		if not (mode == "multipart" and k:lower() == "content-type") then
			headers[#headers + 1] = k .. ": " .. M.substitute(v, spec.vars)
		end
	end
	table.sort(headers)
	for _, h in ipairs(headers) do
		vim.list_extend(args, { "-H", h })
	end

	if body and body ~= "" then
		local fields = {}
		if mode == "multipart" or mode == "urlencoded" then
			for line in body:gmatch("[^\r\n]+") do
				if line:match("=") then
					fields[#fields + 1] = line
				end
			end
		end
		if mode == "multipart" and #fields > 0 then
			for _, f in ipairs(fields) do
				-- `key=@path` reads the file (curl -F); relative paths resolve
				-- against the request file's directory, not nvim's cwd
				local name, val = f:match("^([^=]+)=(.*)$")
				if val and val:sub(1, 1) == "@" then
					local p = val:sub(2)
					if spec.cwd and not p:match("^/") then
						p = spec.cwd .. "/" .. p
					end
					vim.list_extend(args, { "-F", name .. "=@" .. p })
				else
					vim.list_extend(args, { "-F", f })
				end
			end
		elseif mode == "urlencoded" and #fields > 0 then
			for _, f in ipairs(fields) do
				vim.list_extend(args, { "--data-urlencode", f })
			end
		else
			vim.list_extend(args, { "--data-binary", "@-" })
		end
	end
	if marker then
		vim.list_extend(args, {
			"-w",
			string.format(
				"\n%s %%{http_code} %%{time_total} %%{size_download} %%{time_namelookup} %%{time_connect} %%{time_appconnect} %%{time_pretransfer} %%{time_starttransfer} %%{num_redirects}",
				marker
			),
		})
	end
	vim.list_extend(args, { M.resolve_url(spec) })
	return args
end

local function inject_auth(spec, token)
	local headers = {}
	for k, v in pairs(spec.headers or {}) do
		headers[k] = v
	end
	headers.Authorization = "Bearer " .. token
	spec.headers = headers
	return spec
end

local function next_marker()
	seq = seq + 1
	return "@@tuiter" .. seq .. "@@"
end

--- Follow `Link: <url>; rel="next"` headers (# @paginate), up to max_pages.
--- JSON-array pages are concatenated into one array; anything else is joined
--- with newlines. The final response carries paginated/page_count marks.
local function paginate(spec, curl_opts, cwd, pages, max_pages, done)
	local last = pages[#pages]
	local next_url = nil
	for hk, hv in last.headers:gmatch("([^:\r\n]+):%s*([^\r\n]*)") do
		if hk:lower() == "link" then
			next_url = hv:match("<([^>]+)>%s*;%s*rel=%s*[\"']next[\"']?") or next_url
		end
	end
	if not next_url or #pages >= max_pages then
		local first, bodies = pages[1], {}
		local all_arrays = true
		for _, p in ipairs(pages) do
			bodies[#bodies + 1] = p.body
			if p.body:match("^%s*%[") == nil then
				all_arrays = false
			end
		end
		local body
		if all_arrays then
			local out = {}
			for _, p in ipairs(pages) do
				local ok, arr = pcall(vim.json.decode, p.body)
				if ok and type(arr) == "table" then
					for _, v in ipairs(arr) do
						out[#out + 1] = v
					end
				end
			end
			body = vim.json.encode(out)
		else
			body = table.concat(bodies, "\n")
		end
		local merged = vim.deepcopy(first)
		merged.body = body
		merged.paginated = true
		merged.page_count = #pages
		merged.time = 0
		merged.size = 0
		for _, p in ipairs(pages) do
			merged.time = (merged.time or 0) + (p.time or 0)
			merged.size = (merged.size or 0) + (p.size or 0)
		end
		done(merged)
		return
	end
	local page_spec = vim.deepcopy(spec)
	page_spec.url = M.substitute(next_url, spec.vars)
	page_spec.method = "GET"
	page_spec.body = nil
	local marker = next_marker()
	local proc
	proc = vim.system(M.curl_args(page_spec, curl_opts, marker), { text = true, stdin = "" }, function(out)
		M.state.procs[proc] = nil
		pages[#pages + 1] = M.parse_response(out.stdout, out.stderr, out.code, marker, out.signal)
		vim.schedule(function()
			paginate(spec, curl_opts, cwd, pages, max_pages, done)
		end)
	end)
	M.state.procs[proc] = true
end

local function do_send(spec, curl_opts, cwd, cb)
	local marker = next_marker()
	local args = M.curl_args(spec, curl_opts, marker)
	local body = spec.body and M.substitute(spec.body, spec.vars) or nil
	local proc
	proc = vim.system(args, { text = true, stdin = body or "" }, function(out)
		M.state.procs[proc] = nil
		cb(M.parse_response(out.stdout, out.stderr, out.code, marker, out.signal))
	end)
	M.state.procs[proc] = true
end

--- Run a `# @before` / `# @after` Lua script. The script runs in a sandbox
--- with access to `request`, `response` (after only), `set_header`, `set_var`,
--- `set_env`, and `print` (collected into notify). Returns true on success.
local function run_script(code, context)
	if not code or code == "" then
		return true
	end
	local env = {
		print = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				parts[#parts + 1] = tostring(select(i, ...))
			end
			vim.notify("Tuiter script: " .. table.concat(parts, "\t"), vim.log.levels.INFO, { title = "Tuiter" })
		end,
		set_header = function(k, v)
			if context.request then
				context.request.headers = context.request.headers or {}
				context.request.headers[k] = v
			end
		end,
		set_var = function(k, v)
			if context.request then
				context.request.vars = context.request.vars or {}
				context.request.vars[k] = v
			end
		end,
		set_env = function(k, v)
			M.state.env_vars[k] = v
		end,
		request = context.request,
		response = context.response,
		status = context.response and context.response.status or nil,
		body = context.response and context.response.body or nil,
		json = function(s)
			return pcall(vim.json.decode, s or "")
		end,
	}
	setmetatable(env, { __index = _G })
	local fn, load_err = load(code, "@tuiter-script", "t", env)
	if not fn then
		vim.notify("Tuiter script error: " .. tostring(load_err), vim.log.levels.ERROR, { title = "Tuiter" })
		return false
	end
	local ok, err = pcall(fn)
	if not ok then
		vim.notify("Tuiter script error: " .. tostring(err), vim.log.levels.ERROR, { title = "Tuiter" })
		return false
	end
	return true
end

--- Send a request via curl (async).
--- spec: { method, url, headers={k=v}, body=nil|string, vars={k=v}, auth?, tests? }
--- Handles OAuth2/bearer auth, # @test assertions (evaluated into
--- resp.tests / resp.failures) and # @paginate pagination.
function M.send(spec, curl_opts, cwd, cb)
	-- # @delay N: wait N ms before sending (pacing in run-all, "wait for a
	-- background job" polling). Stripped so the recursive call doesn't loop.
	local delay = tonumber((spec.opts or {}).delay)
	if delay and delay > 0 then
		spec.opts.delay = nil
		vim.defer_fn(function()
			M.send(spec, curl_opts, cwd, cb)
		end, delay)
		return
	end
	-- run # @before script (can modify headers, vars)
	local scripts = spec.opts and spec.opts.scripts
	if scripts and scripts.before then
		run_script(scripts.before, { request = spec })
	end
	local done = function(resp)
		if resp then
			M.eval_tests(spec.tests, resp)
			-- run # @after script (can inspect response, set env vars)
			if scripts and scripts.after then
				run_script(scripts.after, { request = spec, response = resp })
			end
		end
		cb(resp)
	end
	-- pagination path (# @paginate / # @max-pages)
	local paginated = function()
		local max_pages = tonumber((spec.opts or {}).max_pages) or 5
		local marker = next_marker()
		local proc
		proc = vim.system(M.curl_args(spec, curl_opts, marker), { text = true, stdin = "" }, function(out)
			M.state.procs[proc] = nil
			local first = M.parse_response(out.stdout, out.stderr, out.code, marker, out.signal)
			vim.schedule(function()
				paginate(spec, curl_opts, cwd, { first }, max_pages, done)
			end)
		end)
		M.state.procs[proc] = true
	end
	-- execute the request (respecting pagination), evaluating 401-refresh retry
	local perform = function()
		if spec.opts and spec.opts.paginate then
			paginated()
			return
		end
		do_send(spec, curl_opts, cwd, function(resp)
			-- 401 + refresh: invalidate the cached token and retry once via the
			-- refresh grant — works for an explicit `# @auth refresh` and for an
			-- `oauth2` flow whose token endpoint returned a refresh_token
			if resp.status == 401 and spec.auth then
				local auth = require("tuiter.auth")
				local refresh = auth.refresh_flow(spec.auth)
				if refresh then
					auth.invalidate(spec.auth)
					auth.ensure_token(refresh, cwd, curl_opts, function(t2)
						if t2 then
							spec = inject_auth(spec, t2)
							do_send(spec, curl_opts, cwd, done)
						else
							done(resp)
						end
					end)
					return
				end
			end
			done(resp)
		end)
	end
	if spec.auth then
		require("tuiter.auth").ensure_token(spec.auth, cwd, curl_opts, function(token)
			if not token then
				cb({ ok = false, status = 0, headers = "", body = "", error = "OAuth2 token fetch failed" })
				return
			end
			spec = inject_auth(spec, token)
			perform()
		end)
	else
		perform()
	end
end

--- Stream a response body as it arrives (# @stream): curl -N, chunks
--- forwarded to on_chunk(data); on_done(code) fires when the process exits.
function M.send_stream(spec, curl_opts, cwd, on_chunk, on_done)
	local args = M.curl_args(spec, curl_opts, nil)
	table.insert(args, 2, "-N") -- no buffering: stream chunks as they arrive
	local body = spec.body and M.substitute(spec.body, spec.vars) or nil
	local proc
	proc = vim.system(args, {
		text = true,
		stdin = body or "",
		stdout = function(_, data)
			if data then
				vim.schedule(function()
					on_chunk(data)
				end)
			end
		end,
		stderr = function(_, data)
			if data then
				vim.schedule(function()
					on_chunk(data)
				end)
			end
		end,
	}, function(out)
		M.state.procs[proc] = nil
		on_done(out.code)
	end)
	M.state.procs[proc] = true
end

--- Kill every in-flight request (e.g. a hanging endpoint).
function M.cancel()
	for proc in pairs(M.state.procs) do
		pcall(proc.kill, proc, 15) -- SIGTERM
	end
	M.state.procs = {}
end

--- # @save <path>: write the response body to a file when the request lands.
--- The path supports {{vars}}; relative paths resolve against the request
--- file's directory. No-op when the request has no # @save directive or
--- failed to complete. Called from init.lua after record_response.
function M.save_response(spec, resp)
	local save = spec and spec.opts and spec.opts.save
	if type(save) ~= "string" or save == "" or not resp or not resp.ok then
		return
	end
	local path = M.substitute(save, spec.vars)
	if spec.cwd and not path:match("^/") then
		path = spec.cwd .. "/" .. path
	end
	-- vim.fn.* is illegal inside vim.system callbacks (E5560); defer the IO
	-- to the main loop. Safe to call from an already-scheduled context too.
	vim.schedule(function()
		local dir = vim.fn.fnamemodify(path, ":h")
		if dir ~= "" then
			vim.fn.mkdir(dir, "p")
		end
		local ok, err = pcall(vim.fn.writefile, vim.split(resp.body or "", "\n", { plain = true }), path)
		if ok then
			vim.notify("Tuiter: saved response body to " .. path, vim.log.levels.INFO, { title = "Tuiter" })
		else
			vim.notify("Tuiter: failed to save " .. path .. ": " .. tostring(err), vim.log.levels.ERROR, { title = "Tuiter" })
		end
	end)
end

local function shq(s) -- single-quote for shell, escaping embedded quotes
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Shell-safe curl command for a spec (Insomnia's "copy as curl").
function M.curl_command(spec, curl_opts)
	local args = M.curl_args(spec, curl_opts, nil)
	local body = spec.body and M.substitute(spec.body, spec.vars) or nil
	local parts = {}
	for _, a in ipairs(args) do
		if a == "@-" then
			parts[#parts + 1] = shq(body or "")
		else
			parts[#parts + 1] = shq(a)
		end
	end
	return table.concat(parts, " ")
end

--- Pretty-print a JSON string (nil when it doesn't parse).
function M.pretty_json(body)
	local ok, data = pcall(vim.json.decode, body)
	if not ok then
		return nil
	end
	local function dump(v, indent)
		indent = indent or ""
		if type(v) == "table" then
			local keys = vim.tbl_keys(v)
			table.sort(keys)
			if #keys == 0 then
				return "{}"
			end
			if v[1] ~= nil then
				local parts = {}
				for _, item in ipairs(v) do
					parts[#parts + 1] = dump(item, indent .. "  ")
				end
				return "[\n" .. indent .. "  " .. table.concat(parts, ",\n" .. indent .. "  ") .. "\n" .. indent .. "]"
			end
			local parts = {}
			for _, k in ipairs(keys) do
				parts[#parts + 1] = dump(tostring(k), indent .. "  ") .. ": " .. dump(v[k], indent .. "  ")
			end
			return "{\n" .. indent .. "  " .. table.concat(parts, ",\n" .. indent .. "  ") .. "\n" .. indent .. "}"
		elseif type(v) == "string" then
			return vim.json.encode(v)
		end
		return tostring(v)
	end
	return dump(data)
end

return M
