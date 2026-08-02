--- GraphQL file support (.graphql / .gql), Insomnia-style:
---
---   # @url https://api.example.com/graphql
---   # @variables {"userId": "{{user_id}}"}
---
---   query GetUser($id: ID!) {
---     user(id: $id) { name }
---   }
---
---   mutation UpdateUser {
---     updateUser(input: {name: "ada"}) { id }
---   }
---
--- Each operation becomes a POST request whose JSON body is
--- { "query": <operation text>, "variables": <@variables or null> }.
--- `# @url` is taken from the nearest preceding directive (or the first one).
local M = {}

---@param lines string[]
---@return table[] requests (same shape as parser.parse_lines output)
function M.parse(lines)
	local requests = {}
	local url = nil
	local pending_vars = nil
	local cur = nil -- { name, text, start_line, vars }
	local depth = 0

	local function flush()
		if not cur then
			return
		end
		local variables = cur.vars or pending_vars
		local body
		if variables then
			body = vim.json.encode({ query = cur.text, variables = variables })
		else
			body = vim.json.encode({ query = cur.text })
		end
		requests[#requests + 1] = {
			name = cur.name,
			method = "POST",
			url = cur.url,
			headers = { ["Content-Type"] = "application/json" },
			body = body,
			line = cur.start_line,
			vars = {},
			opts = {},
		}
		cur = nil
	end

	for i, raw in ipairs(lines) do
		local line = (raw or ""):gsub("\r$", "")
		if cur then
			cur.text = cur.text .. line .. "\n"
			for ch in line:gmatch("[{}]") do
				if ch == "{" then
					depth = depth + 1
				else
					depth = depth - 1
				end
			end
			if depth <= 0 then
				cur.text = cur.text:gsub("\n+$", "")
				flush()
			end
		elseif line:match("^#%s*@url") then
			url = line:match("^#%s*@url%s*[=:]?%s*(.-)%s*$") or url
			pending_vars = nil
		elseif line:match("^#%s*@variables") then
			local ok, data = pcall(vim.json.decode, line:match("^#%s*@variables%s*(.-)%s*$") or "null")
			pending_vars = ok and data or pending_vars
		else
			-- Lua patterns have no alternation: match the first word, then compare
			local w = line:match("^%s*([%a_]+)")
			if w == "query" or w == "mutation" or w == "subscription" then
				local name = line:match("^%s*" .. w .. "%s+([%w_]+)") or w
				cur = {
					name = name,
					text = line,
					start_line = i,
					url = url,
					vars = pending_vars,
				}
				pending_vars = nil
				depth = 0
				for ch in line:gmatch("[{}]") do
					if ch == "{" then
						depth = depth + 1
					else
						depth = depth - 1
					end
				end
				if depth <= 0 then
					flush()
				end
			end
		end
	end
	flush()
	return requests
end

return M
