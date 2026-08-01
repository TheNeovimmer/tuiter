--- Parses .http files (REST Client style) into request specs.
--- Pure Lua: no vim.* dependencies, so it can run in plain tests.
local M = {}

--- Parse a list of lines into requests.
--- Each request: { name, method, url, headers={k=v}, body=nil|string, line=int, vars={k=v} }
function M.parse_lines(lines)
	local requests = {}
	local cur = nil
	local in_body = false

	local function start(line, i)
		cur = { name = "", headers = {}, body = nil, line = i, vars = {} }
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
			-- comment, skip
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
