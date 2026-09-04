--- tuiter: request template management.
--- Templates are saved request patterns that can be inserted into .http files.
local M = {}

local uv = vim.uv or vim.loop

--- Template storage directory.
---@return string
local function templates_dir()
	local dir = vim.fn.stdpath("data") .. "/tuiter/templates"
	if vim.fn.isdirectory(dir) ~= 1 then
		vim.fn.mkdir(dir, "p")
	end
	return dir
end

--- List all saved templates.
---@return table[]
function M.list()
	local dir = templates_dir()
	local templates = {}
	local handle = uv.fs_scandir(dir)
	if not handle then
		return templates
	end
	while true do
		local name, typ = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if typ == "file" and name:match("%.json$") then
			local path = dir .. "/" .. name
			local content = table.concat(vim.fn.readfile(path), "\n")
			local ok, data = pcall(vim.json.decode, content)
			if ok and data.name then
				table.insert(templates, {
					name = data.name,
					description = data.description or "",
					method = data.method or "GET",
					path = path,
					content = data.content or "",
				})
			end
		end
	end
	table.sort(templates, function(a, b)
		return a.name < b.name
	end)
	return templates
end

--- Save a request as a template.
---@param name string
---@param content string
---@param description? string
---@param method? string
---@return boolean, string?
function M.save(name, content, description, method)
	if not name or name == "" then
		return false, "Template name required"
	end

	local dir = templates_dir()
	local path = dir .. "/" .. name .. ".json"

	-- Extract method from content if not provided
	if not method then
		method = content:match("^%s*(%u+)%s+") or "GET"
	end

	local data = {
		name = name,
		description = description or "",
		method = method,
		content = content,
		created = os.time(),
	}

	local json = vim.json.encode(data)
	local lines = vim.split(json, "\n")
	local ok = vim.fn.writefile(lines, path)
	if ok ~= 0 then
		return false, "Failed to save template"
	end

	return true, nil
end

--- Delete a template.
---@param name string
---@return boolean, string?
function M.delete(name)
	local dir = templates_dir()
	local path = dir .. "/" .. name .. ".json"
	if vim.fn.filereadable(path) ~= 1 then
		return false, "Template not found: " .. name
	end
	local ok = vim.fn.delete(path)
	if ok ~= 0 then
		return false, "Failed to delete template"
	end
	return true, nil
end

--- Get template content by name.
---@param name string
---@return string?
function M.get(name)
	local dir = templates_dir()
	local path = dir .. "/" .. name .. ".json"
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	local content = table.concat(vim.fn.readfile(path), "\n")
	local ok, data = pcall(vim.json.decode, content)
	if not ok then
		return nil
	end
	return data.content
end

--- Insert template content at cursor position.
---@param name string
---@return boolean, string?
function M.insert(name)
	local content = M.get(name)
	if not content then
		return false, "Template not found: " .. name
	end

	local lines = vim.split(content, "\n")
	local buf = vim.api.nvim_get_current_buf()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))

	-- Find {{cursor}} placeholder and position there
	local cursor_line = 1
	local cursor_col = 0
	for i, line in ipairs(lines) do
		local pos = line:find("{{cursor}}")
		if pos then
			cursor_line = i - 1
			cursor_col = pos - 1
			lines[i] = line:gsub("{{cursor}}", "")
			break
		end
	end

	vim.api.nvim_buf_set_lines(buf, row - 1, row - 1, false, lines)

	-- Position cursor
	if #lines > 0 then
		vim.api.nvim_win_set_cursor(0, { row + cursor_line, cursor_col })
	end

	return true, nil
end

--- Built-in templates.
M.builtin = {
	{
		name = "GET request",
		description = "Basic GET request",
		method = "GET",
		content = [[### {{cursor}}
GET https://api.example.com/endpoint
Accept: application/json]],
	},
	{
		name = "POST JSON",
		description = "POST request with JSON body",
		method = "POST",
		content = [[### {{cursor}}
POST https://api.example.com/endpoint
Content-Type: application/json

{
  "key": "value"
}]],
	},
	{
		name = "POST form",
		description = "POST request with form data",
		method = "POST",
		content = [[### {{cursor}}
POST https://api.example.com/endpoint
Content-Type: application/x-www-form-urlencoded

key1=value1&key2=value2]],
	},
	{
		name = "PUT update",
		description = "PUT request for updating resources",
		method = "PUT",
		content = [[### {{cursor}}
PUT https://api.example.com/endpoint/1
Content-Type: application/json

{
  "key": "value"
}]],
	},
	{
		name = "DELETE",
		description = "DELETE request",
		method = "DELETE",
		content = [[### {{cursor}}
DELETE https://api.example.com/endpoint/1]],
	},
	{
		name = "Auth bearer",
		description = "Request with bearer token",
		method = "GET",
		content = [[### {{cursor}}
GET https://api.example.com/me
Authorization: Bearer {{$body.token}}]],
	},
	{
		name = "Pagination",
		description = "Paginated GET request",
		method = "GET",
		content = [[### {{cursor}}
# @paginate
# @max-pages 10
GET https://api.example.com/items?page=1]],
	},
	{
		name = "GraphQL query",
		description = "GraphQL query",
		method = "POST",
		content = [[### {{cursor}}
# @url http://localhost:4000/graphql
# @variables {"userId": "1"}

query GetUser($id: ID!) {
  user(id: $id) {
    name
    email
  }
}]],
	},
	{
		name = "Health check",
		description = "Simple health check endpoint",
		method = "GET",
		content = [[### {{cursor}}
# @test status == 200
# @test body.status == "ok"
GET https://api.example.com/health]],
	},
	{
		name = "Login flow",
		description = "Login and store token",
		method = "POST",
		content = [[### Login
# @name login
# @test status == 200
# @after set_env("token", json(body).token)
POST https://api.example.com/login
Content-Type: application/json

{"email": "user@example.com", "password": "secret"}

### Use token
GET https://api.example.com/me
Authorization: Bearer {{login.body.token}}]],
	},
}

--- Get all templates (built-in + saved).
---@return table[]
function M.all()
	local all = {}
	-- Add built-in templates
	for _, t in ipairs(M.builtin) do
		table.insert(all, vim.deepcopy(t))
	end
	-- Add saved templates
	for _, t in ipairs(M.list()) do
		table.insert(all, t)
	end
	return all
end

return M