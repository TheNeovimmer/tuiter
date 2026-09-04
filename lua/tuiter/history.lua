--- Request history, persisted to stdpath("data")/tuiter/history.json.
local M = {}

local MAX = 200

-- Secrets never written to history (screenshots happen): the header VALUE is
-- dropped entirely so a leaked history.json doesn't leak credentials.
local REDACT_HEADERS = {
	["authorization"] = true,
	["proxy-authorization"] = true,
	["cookie"] = true,
	["x-api-key"] = true,
	["x-auth-token"] = true,
	["set-cookie"] = true,
}

local function redact_spec(spec)
	local headers = {}
	for k, v in pairs(spec.headers or {}) do
		if not REDACT_HEADERS[k:lower()] then
			headers[k] = v
		end
	end
	return headers
end

local function file()
	return vim.fn.stdpath("data") .. "/tuiter/history.json"
end

function M.load()
	local f = file()
	if vim.fn.filereadable(f) == 0 then
		return {}
	end
	local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(f), "\n"))
	if not ok or type(data) ~= "table" then
		return {}
	end
	return data
end

function M.add(spec, resp)
	local h = M.load()
	local entry = {
		ts = os.time(),
		method = spec.method,
		url = spec.url,
		name = spec.name or "",
		status = resp.status,
		time = resp.time,
		size = resp.size,
		spec = {
			method = spec.method,
			url = spec.url,
			headers = redact_spec(spec),
			body = spec.body,
			vars = spec.vars,
			name = spec.name or "",
			cwd = spec.cwd,
			opts = spec.opts, -- keep # @base / # @save / # @timeout etc. on replay
		},
	}
	-- dedupe consecutive identical requests: refresh the head entry instead
	-- of piling up (e.g. repeated <leader>is on the same request)
	local head = h[1]
	if head and head.method == entry.method and head.url == entry.url and (head.spec.body or "") == (spec.body or "") then
		head.ts, head.status, head.time, head.size = entry.ts, entry.status, entry.time, entry.size
	else
		table.insert(h, 1, entry)
	end
	while #h > MAX do
		table.remove(h)
	end
	vim.fn.mkdir(vim.fn.stdpath("data") .. "/tuiter", "p")
	pcall(vim.fn.writefile, { vim.json.encode(h) }, file())
end

--- Pick an entry via vim.ui.select (integrates with the user's picker),
--- then call cb(entry.spec) with the stored request.
function M.pick(cb)
	local h = M.load()
	if #h == 0 then
		vim.notify("Tuiter: history is empty", vim.log.levels.INFO, { title = "Tuiter" })
		return
	end
	vim.ui.select(h, {
		prompt = "Tuiter history",
		format_item = function(e)
			-- extract {{vars}} used in the request for preview
			local vars = {}
			if e.spec then
				local function collect(str)
					if type(str) == "string" then
						for v in str:gmatch("{{" .. "([%w_$%.]+)" .. "}}") do
							vars[#vars + 1] = v
						end
					end
				end
				collect(e.spec.url)
				if e.spec.headers then
					for _, hv in pairs(e.spec.headers) do
						collect(hv)
					end
				end
				collect(e.spec.body)
			end
			local var_str = #vars > 0 and ("  vars: " .. table.concat(vars, ", ")) or ""
			return string.format(
				"%s %-6s %s %s%s",
				os.date("%m-%d %H:%M", e.ts),
				e.method,
				e.url,
				e.name ~= "" and ("(" .. e.name .. ") ") or "",
				e.status and ("[" .. e.status .. "]" .. var_str) or var_str
			)
		end,
	}, function(entry)
		if entry then
			cb(entry.spec)
		end
	end)
end

return M
