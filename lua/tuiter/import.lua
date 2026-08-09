--- Convert Postman collections and OpenAPI specs into tuiter .http files.
--- Pure functions (decode JSON, return the .http text) so they're testable
--- headlessly. Commands in plugin/tuiter.lua wrap them.
local M = {}

local METHODS = { "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" }

--- Flatten a nested Postman `item` tree into a list of request objects.
local function flatten_postman(items, out)
	out = out or {}
	for _, item in ipairs(items or {}) do
		if item.item then
			flatten_postman(item.item, out)
		elseif item.request then
			local req = item.request
			if type(req) == "string" then
				req = { method = "GET", url = req }
			end
			local url = type(req.url) == "string" and req.url or (req.url and (req.url.raw or req.url) or "")
			local headers = {}
			for _, h in ipairs(req.header or {}) do
				if type(h) == "table" and h.key then
					headers[h.key] = h.value
				end
			end
			local body
			if type(req.body) == "table" then
				if req.body.mode == "raw" then
					body = req.body.raw
				elseif req.body.mode == "urlencoded" then
					local parts = {}
					for _, p in ipairs(req.body.urlencoded or {}) do
						parts[#parts + 1] = p.key .. "=" .. p.value
					end
					body = table.concat(parts, "\n")
					headers["Content-Type"] = headers["Content-Type"] or "application/x-www-form-urlencoded"
				end
			end
			out[#out + 1] = {
				name = item.name or "",
				method = (req.method or "GET"):upper(),
				url = url,
				headers = headers,
				body = body,
			}
		end
	end
	return out
end

--- Compose .http text from parsed request objects.
local function to_http(requests)
	local lines = {}
	for _, r in ipairs(requests) do
		if r.name ~= "" then
			lines[#lines + 1] = "### " .. r.name
		end
		lines[#lines + 1] = (r.method or "GET") .. " " .. r.url
		if r.schema then
			lines[#lines + 1] = "Content-Type: application/json"
		end
		for k, v in pairs(r.headers) do
			if k:lower() ~= "content-type" or not r.schema then
				lines[#lines + 1] = k .. ": " .. (v or "")
			end
		end
		if r.body and r.body ~= "" then
			lines[#lines + 1] = ""
			lines[#lines + 1] = r.body
		end
		lines[#lines + 1] = ""
	end
	return table.concat(lines, "\n")
end

--- Convert a Postman collection (JSON string) to .http text.
---@param json_str string
---@return string, string? error
function M.postman(json_str)
	local ok, coll = pcall(vim.json.decode, json_str)
	if not ok or type(coll) ~= "table" then
		return "", "not a valid Postman collection JSON"
	end
	return to_http(flatten_postman(coll.item or {})), nil
end

--- Convert an OpenAPI 3.x / Swagger spec (JSON string) to .http text.
--- Each path+method becomes a request; query params are appended to the URL
--- and the example requestBody (if any) becomes the body.
---@param json_str string
---@return string, string? error
function M.openapi(json_str)
	local ok, spec = pcall(vim.json.decode, json_str)
	if not ok or type(spec) ~= "table" then
		return "", "not a valid OpenAPI JSON spec"
	end
	local requests = {}
	local server = nil
	if type(spec.servers) == "table" and type(spec.servers[1]) == "table" then
		server = spec.servers[1].url
	end
	local function clean_url(u)
		return u:gsub("{[%w_]+}", ":param")
	end
	for path, ops in pairs(spec.paths or {}) do
		if type(ops) == "table" then
			for _, m in ipairs(METHODS) do
				local op = ops[m:lower()]
				if type(op) == "table" then
					local url = (server or "") .. clean_url(path)
					local qp = {}
					for _, p in ipairs(op.parameters or {}) do
						if p["in"] == "query" then
							local dv = p.schema and p.schema.example or p.example
							qp[#qp + 1] = p.name .. "=" .. (dv ~= nil and tostring(dv) or "")
						end
					end
					if #qp > 0 then
						url = url .. "?" .. table.concat(qp, "&")
					end
					local body = nil
					if type(op.requestBody) == "table" and type(op.requestBody.content) == "table" then
						local jc = op.requestBody.content["application/json"]
						if type(jc) == "table" and jc.example ~= nil then
							body = vim.json.encode(jc.example)
						end
					end
					requests[#requests + 1] = {
						name = op.operationId or (m .. " " .. path),
						method = m,
						url = url,
						headers = {}, -- Content-Type added via schema flag when body is json
						body = body,
						schema = body ~= nil,
					}
				end
			end
		end
	end
	table.sort(requests, function(a, b)
		return a.url < b.url
	end)
	return to_http(requests), nil
end

-- ---------------------------------------------------------------------------
-- curl command import (:TuiterImportCurl) — DevTools / docs / `gh api -i`
-- ---------------------------------------------------------------------------

--- Split a shell-ish command line into tokens (single/double quotes).
local function tokenize(str)
	local toks, i, n = {}, 1, #str
	while i <= n do
		local c = str:sub(i, i)
		if c:match("%s") then
			i = i + 1
		elseif c == "'" or c == '"' then
			local q, buf = c, {}
			i = i + 1
			while i <= n do
				local ch = str:sub(i, i)
				if ch == q then
					break
				elseif ch == "\\" and q == '"' and i < n then
					buf[#buf + 1] = str:sub(i + 1, i + 1)
					i = i + 2
				else
					buf[#buf + 1] = ch
					i = i + 1
				end
			end
			toks[#toks + 1] = table.concat(buf)
			i = i + 1
		else
			local start = i
			while i <= n and not str:sub(i, i):match("%s") do
				i = i + 1
			end
			toks[#toks + 1] = str:sub(start, i - 1)
		end
	end
	return toks
end

--- Percent-encode a query value for the -G path.
local function urlencode(s)
	return (s:gsub("[^%w%-%_%.%~]", function(ch)
		return string.format("%%%02X", ch:byte())
	end))
end

-- curl flags that take an argument (everything else is ignored: -L, -sS,
-- --compressed, -i, --fail … are tuiter defaults)
local FLAG_WITH_ARG = {
	["-X"] = true,
	["--request"] = true,
	["-H"] = true,
	["--header"] = true,
	["-d"] = true,
	["--data"] = true,
	["--data-raw"] = true,
	["--data-binary"] = true,
	["--data-urlencode"] = true,
	["-F"] = true,
	["--form"] = true,
	["-u"] = true,
	["--user"] = true,
	["-A"] = true,
	["--user-agent"] = true,
	["-e"] = true,
	["--referer"] = true,
	["-b"] = true,
	["--cookie"] = true,
	["-o"] = true,
	["--output"] = true,
	["--max-time"] = true,
	["--connect-timeout"] = true,
	["--retry"] = true,
	["--retry-delay"] = true,
	["--max-redirs"] = true,
	["--cert"] = true,
	["--key"] = true,
	["--proxy"] = true,
}

--- Convert a curl command string to tuiter .http text.
---@param str string
---@return string, string? error
function M.curl(str)
	local toks = tokenize(str)
	local req = {
		method = nil,
		url = nil,
		headers = {},
		data = {}, -- -d / --data* payloads
		forms = {}, -- -F fields
		get_query = false, -- -G: data becomes the query string
		insecure = false,
	}
	local i = 1
	while i <= #toks do
		local t = toks[i]
		if t:sub(1, 1) == "-" and t ~= "-" then
			if FLAG_WITH_ARG[t] then
				local v = toks[i + 1]
				i = i + 1
				if v then
					if t == "-X" or t == "--request" then
						req.method = v:upper()
					elseif t == "-H" or t == "--header" then
						local k, val = v:match("^([^:]+):%s*(.*)$")
						if k then
							req.headers[k] = val
						end
					elseif t == "-F" or t == "--form" then
						req.forms[#req.forms + 1] = v
					elseif t == "-u" or t == "--user" then
						req.headers.Authorization = "Basic " .. vim.base64.encode(v)
					elseif t == "-A" or t == "--user-agent" then
						req.headers["User-Agent"] = v
					elseif t == "-e" or t == "--referer" then
						req.headers.Referer = v
					elseif t == "-b" or t == "--cookie" then
						-- inline k=v pairs become a Cookie header; a bare path is a
						-- cookie jar (skipped — tuiter manages jars itself)
						if v:match("=") then
							req.headers.Cookie = v
						end
					elseif t == "-d" or t == "--data" or t == "--data-raw" or t == "--data-binary" then
						req.data[#req.data + 1] = v
					elseif t == "--data-urlencode" then
						req.data[#req.data + 1] = v
						req.get_query = true
					end
				end
			elseif t == "-G" or t == "--get" then
				req.get_query = true
			elseif t == "-k" or t == "--insecure" then
				req.insecure = true
			end
		elseif t ~= "curl" and not req.url and (t:match("^%a[%w%.%-]*://") or t:match("^{{")) then
			req.url = t
		end
		i = i + 1
	end
	if not req.url then
		return "", "no URL found in the curl command"
	end

	local method, body = req.method, nil
	if #req.forms > 0 then
		-- multipart: k=v lines; tuiter sends them as curl -F fields
		req.headers["Content-Type"] = req.headers["Content-Type"] or "multipart/form-data"
		body = table.concat(req.forms, "\n")
		method = method or "POST"
	elseif req.get_query and #req.data > 0 and not (method == "POST" or method == "PUT" or method == "PATCH") then
		-- -G: the data becomes the query string
		local q = {}
		for _, d in ipairs(req.data) do
			local k, v = d:match("^([^=]+)=(.*)$")
			q[#q + 1] = urlencode(k) .. "=" .. urlencode(v or "")
		end
		req.url = req.url .. (req.url:find("?", 1, true) and "&" or "?") .. table.concat(q, "&")
	elseif #req.data > 0 then
		method = method or "POST"
		local all_fields = true
		for _, d in ipairs(req.data) do
			if not d:match("^[^=]+=") then
				all_fields = false
				break
			end
		end
		if all_fields then
			-- k=v form fields: mark the content type so tuiter re-encodes values
			-- via curl --data-urlencode. Multi-field bodies go one line per field
			-- (joining with & would make tuiter fall back to a raw --data-binary).
			req.headers["Content-Type"] = req.headers["Content-Type"] or "application/x-www-form-urlencoded"
			if #req.data > 1 then
				body = table.concat(req.data, "\n")
			else
				body = req.data[1]
			end
		else
			-- single JSON/raw payload (curl joins repeated -d with &)
			body = table.concat(req.data, "&")
		end
	end
	method = method or "GET"

	local lines = {}
	if req.insecure then
		lines[#lines + 1] = "# @insecure"
	end
	lines[#lines + 1] = method .. " " .. req.url
	local keys = vim.tbl_keys(req.headers)
	table.sort(keys)
	for _, k in ipairs(keys) do
		lines[#lines + 1] = k .. ": " .. req.headers[k]
	end
	if body then
		lines[#lines + 1] = ""
		lines[#lines + 1] = body
	end
	return table.concat(lines, "\n"), nil
end

return M
