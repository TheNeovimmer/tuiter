--- Parses .http files (REST Client style) into request specs.
--- Pure Lua: no vim.* dependencies, so it can run in plain tests.
local M = {}

--- Parse a list of lines into requests.
--- Each request: { name, method, url, headers={k=v}, body=nil|string, line=int, vars={k=v}, opts={} }
function M.parse_lines(lines)
	local requests = {}
	local cur = nil
	local in_body = false

	local function start(line, i)
		cur = { name = "", headers = {}, body = nil, line = i, vars = {}, opts = {} }
		local name = line:match("^###%s*(.*)$")
		if name then
			cur.name = name
		end
		requests[#requests + 1] = cur
		in_body = false
	end

	for i, raw in ipairs(lines) do
		local line = (raw or ""):gsub("\r$", "")
		if line:match("^###") then
			start(line, i)
		elseif not cur then
			-- implicit first request (no leading ###)
			local m, u = line:match("^(%u+)%s+(%S+)")
			if m then
				start("", i)
				cur.method, cur.url = m, u
			end
		elseif in_body then
			cur.body = (cur.body or "") .. line .. "\n"
		elseif line == "" then
			in_body = true
		elseif line:match("^#") then
			-- comments + directives: `# @name foo`, `# @timeout 5`,
			-- `# @no-redirect`, `# @no-log` (stored in spec.opts)
			local n = line:match("^#%s*@name%s*[=:]?%s*(.-)%s*$")
			if n then
				cur.name = n
			end
			local k, v = line:match("^#%s*@([%w%-_]+)%s*(.-)%s*$")
			if k and k ~= "name" then
				cur.opts[k:gsub("%-", "_")] = v == "" and true or v
			end
		else
			local k, v = line:match("^([%w%-_]+)%s*:%s*(.*)$")
			if k then
				cur.headers[k] = v
			else
				local name, val = line:match("^@([%w_]+)%s*=%s*(.*)$")
				if name then
					cur.vars[name] = val
				else
					local m, u = line:match("^(%u+)%s+(%S+)")
					if m then
						if cur.method then
							-- bare METHOD URL line: a new request without ###
							start("", i)
						end
						cur.method, cur.url = m, u
					end
				end
			end
		end
	end

	for _, r in ipairs(requests) do
		if r.body then
			r.body = r.body:gsub("\n+$", "")
		end
	end
	return requests
end

--- Lightweight validation for diagnostics in .http buffers.
--- Returns { { lnum=1-based, msg=string } }.
function M.validate(lines)
	local issues = {}
	local in_body = false
	for i, raw in ipairs(lines) do
		local line = (raw or ""):gsub("\r$", "")
		if line:match("^###") then
			in_body = false
		elseif line:match("^%s*$") then
			in_body = true
		elseif not line:match("^#") and not in_body and not line:match("^@") then
			local m, u = line:match("^(%u+)%s+(%S+)")
			if not m then
				local bare = line:match("^(%u+)$")
				if bare then
					issues[#issues + 1] = { lnum = i, msg = "method " .. bare .. " is missing a URL" }
				elseif line:match("^[%w%-_]+:%s*//") then
					issues[#issues + 1] = { lnum = i, msg = "URL does not start with http(s):// — did you forget the METHOD?" }
				elseif not line:match("^[%w%-_]+:") then
					issues[#issues + 1] =
						{ lnum = i, msg = "expected METHOD URL or Header: value (or a blank line before the body)" }
				end
			elseif not u:match("^https?://") and not u:match("^{{") then
				issues[#issues + 1] = { lnum = i, msg = "URL '" .. u:sub(1, 40) .. "' does not start with http(s)://" }
			end
		end
	end
	return issues
end

--- The request whose start line is at or before `lnum` (1-based), if any.
function M.at(requests, lnum)
	local best
	for _, r in ipairs(requests) do
		if r.line <= lnum then
			best = r
		end
	end
	return best
end

return M
