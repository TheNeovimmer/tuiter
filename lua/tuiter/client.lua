--- HTTP client: env/var resolution + curl dispatch + response parsing.
local M = {
	state = { env = nil, env_file = nil, env_vars = {} },
}

local seq = 0

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

--- Replace {{var}} placeholders: request vars > env vars > os env. Unresolved
--- names are left untouched so the user sees what's missing.
function M.substitute(str, request_vars)
	if type(str) ~= "string" then
		return str
	end
	return (
		str:gsub("{{([%w_]+)}}", function(name)
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
			return "{{" .. name .. "}}"
		end)
	)
end

--- Parse curl output (built with -i and a trailing write-out marker line).
function M.parse_response(stdout, stderr, exit_code, marker)
	local resp = { ok = exit_code == 0, status = 0, headers = "", body = "", error = stderr }
	local code, t, size = stdout:match("\n" .. marker .. " (%d+) ([%d%.]+) (%d+)\r?\n?$")
	if code then
		resp.status = tonumber(code)
		resp.time = tonumber(t)
		resp.size = tonumber(size)
		stdout = stdout:gsub("\n" .. marker .. " %d+ [%d%.]+ %d+\r?\n?$", "")
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
function M.curl_args(spec, curl_opts, marker)
	local args = { "curl", "-sS", "-i", "-X", spec.method, "--max-time", tostring(curl_opts.timeout or 30) }
	if curl_opts.insecure then
		vim.list_extend(args, { "-k" })
	end
	if curl_opts.max_redirects and curl_opts.max_redirects > 0 then
		vim.list_extend(args, { "-L", "--max-redirs", tostring(curl_opts.max_redirects) })
	end
	local headers = {}
	for k, v in pairs(spec.headers or {}) do
		headers[#headers + 1] = k .. ": " .. M.substitute(v, spec.vars)
	end
	table.sort(headers)
	for _, h in ipairs(headers) do
		vim.list_extend(args, { "-H", h })
	end
	if spec.body and spec.body ~= "" then
		vim.list_extend(args, { "--data-binary", "@-" })
	end
	if marker then
		vim.list_extend(args, { "-w", "\n" .. marker .. " %{http_code} %{time_total} %{size_download}" })
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
	vim.system(args, { text = true, stdin = body or "" }, function(out)
		cb(M.parse_response(out.stdout, out.stderr, out.code, marker))
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
