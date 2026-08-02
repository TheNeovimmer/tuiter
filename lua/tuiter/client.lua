--- HTTP client: env/var resolution + curl dispatch + response parsing.
local M = {
	state = {
		env = nil,
		env_file = nil,
		env_vars = {},
		response = nil, -- last response (for {{$body.*}} / {{$status}})
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
local function env_file_for(dir, opts)
	local d = dir
	local prev = nil
	while d and d ~= prev do
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

function M.set_env(name, dir, opts)
	local path = env_file_for(dir, opts)
	local envs = path and read_env_file(path) or {}
	M.state.env = name
	M.state.env_file = path
	M.state.env_vars = type(envs[name]) == "table" and envs[name] or {}
end

--- Load the default env the first time a project with an env file is used.
function M.ensure_env(dir, opts)
	local path = env_file_for(dir, opts)
	if not path then
		return
	end
	if M.state.env and M.state.env_file == path then
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
		local ok, data = pcall(vim.json.decode, r.body)
		if not ok then
			return "{{" .. name .. "}}"
		end
		for part in name:sub(7):gmatch("[^%.]+") do
			if type(data) ~= "table" then
				return "{{" .. name .. "}}"
			end
			-- JSON array indexes are 0-based (Insomnia-style): .list.0 -> first item
			local n = tonumber(part)
			data = data[n and n + 1 or part]
		end
		if data == nil then
			return "{{" .. name .. "}}"
		end
		if type(data) == "table" then
			return vim.json.encode(data)
		end
		return tostring(data)
	end
	return nil
end

--- Record the last response so later requests can reference it.
function M.record_response(resp)
	M.state.response = resp
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

--- Replace {{var}} placeholders. Resolution order: request vars > env vars >
--- os env > dynamic values ({{$...}}). Unresolved names are left untouched so
--- the user sees what's missing.
function M.substitute(str, request_vars)
	if type(str) ~= "string" then
		return str
	end
	return (
		str:gsub("{{([%w_$%.]+)}}", function(name)
			if request_vars and request_vars[name] ~= nil then
				return tostring(request_vars[name])
			end
			local e = M.state.env_vars[name]
			if e ~= nil then
				return tostring(e)
			end
			local o = vim.env[name]
			if o ~= nil then
				return o
			end
			local d = name:sub(1, 1) == "$" and dynamic(name) or nil
			if d ~= nil then
				return d
			end
			return "{{" .. name .. "}}"
		end)
	)
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
	local timeout = tonumber((spec.opts or {}).timeout) or curl_opts.timeout or 30
	local args = { "curl", "-sS", "-i", "-X", spec.method, "--max-time", tostring(timeout) }
	if curl_opts.insecure then
		vim.list_extend(args, { "-k" })
	end
	local follow = not (spec.opts and spec.opts.no_redirect)
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
				vim.list_extend(args, { "-F", f })
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
	vim.list_extend(args, { M.substitute(spec.url, spec.vars) })
	return args
end

--- Send a request via curl (async).
--- spec: { method, url, headers={k=v}, body=nil|string, vars={k=v} }
function M.send(spec, curl_opts, cwd, cb)
	seq = seq + 1
	local marker = "@@tuiter" .. seq .. "@@"
	local args = M.curl_args(spec, curl_opts, marker)
	local body = spec.body and M.substitute(spec.body, spec.vars) or nil
	local proc
	proc = vim.system(args, { text = true, stdin = body or "" }, function(out)
		M.state.procs[proc] = nil
		cb(M.parse_response(out.stdout, out.stderr, out.code, marker, out.signal))
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
