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

return M
