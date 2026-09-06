--- tuiter: collection management for .http request files.
--- Collections are directories ending in `.http.collections` containing
--- .http files and optional collection-specific env files.
local M = {}

local uv = vim.uv or vim.loop

--- Find the collection root for a given file path.
--- Walks up from `path` looking for a directory ending in `.http.collections`.
---@param path string
---@return string? collection_root, string? collection_name
function M.find_collection(path)
	local dir = vim.fn.fnamemodify(path, ":p:h")
	while dir and dir ~= "" do
		if dir:match("%.http%.collections$") then
			local name = vim.fn.fnamemodify(dir, ":t"):gsub("%.http%.collections$", "")
			return dir, name
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	return nil, nil
end

--- List all .http.collections directories under a root path.
---@param root string
---@return table[]
function M.list_collections(root)
	root = root or vim.fn.getcwd()
	local collections = {}

	local function scan(dir)
		local handle = uv.fs_scandir(dir)
		if not handle then
			return
		end
		while true do
			local name, typ = uv.fs_scandir_next(handle)
			if not name then
				break
			end
			local full = dir .. "/" .. name
			if typ == "directory" then
				if name:match("%.http%.collections$") then
					table.insert(collections, {
						name = name:gsub("%.http%.collections$", ""),
						path = full,
						files = M.list_files(full),
					})
				else
					scan(full)
				end
			end
		end
	end

	scan(root)
	return collections
end

--- List .http files in a collection directory.
---@param collection_path string
---@return table[]
function M.list_files(collection_path)
	local files = {}
	local handle = uv.fs_scandir(collection_path)
	if not handle then
		return files
	end
	while true do
		local name, typ = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if typ == "file" and name:match("%.http$") then
			table.insert(files, {
				name = name,
				path = collection_path .. "/" .. name,
			})
		end
	end
	table.sort(files, function(a, b)
		return a.name < b.name
	end)
	return files
end

--- Create a new collection directory.
---@param name string
---@param root? string
---@return string? path, string? error
function M.create(name, root)
	root = root or vim.fn.getcwd()
	local path = root .. "/" .. name .. ".http.collections"

	if vim.fn.isdirectory(path) == 1 then
		return nil, "Collection already exists: " .. name
	end

	local ok = vim.fn.mkdir(path, "p")
	if ok == 0 then
		return nil, "Failed to create collection: " .. name
	end

	-- Create a README.md in the collection
	local readme = path .. "/README.md"
	vim.fn.writefile({
		"# " .. name .. " Collection",
		"",
		"## Requests",
		"",
		"Place `.http` files in this directory.",
		"",
		"## Environment",
		"",
		"Create `collection.env.json` for collection-specific variables.",
		"These override root-level env files.",
	}, readme)

	return path, nil
end

--- Add a .http file to a collection.
---@param file_path string
---@param collection_path string
---@return boolean, string?
function M.add_file(file_path, collection_path)
	if vim.fn.filereadable(file_path) ~= 1 then
		return false, "File not found: " .. file_path
	end

	if vim.fn.isdirectory(collection_path) ~= 1 then
		return false, "Collection not found: " .. collection_path
	end

	local filename = vim.fn.fnamemodify(file_path, ":t")
	local dest = collection_path .. "/" .. filename

	if vim.fn.filereadable(dest) == 1 then
		return false, "File already exists in collection: " .. filename
	end

	local ok = vim.fn.copyfile(file_path, dest)
	if ok ~= 0 then
		return false, "Failed to copy file to collection"
	end

	return true, nil
end

--- Get collection env file path.
---@param collection_path string
---@return string
function M.env_file(collection_path)
	return collection_path .. "/collection.env.json"
end

--- Read collection env if it exists.
---@param collection_path string
---@return table?
function M.read_env(collection_path)
	local env_path = M.env_file(collection_path)
	if vim.fn.filereadable(env_path) ~= 1 then
		return nil
	end
	local content = table.concat(vim.fn.readfile(env_path), "\n")
	local ok, data = pcall(vim.json.decode, content)
	if not ok then
		return nil
	end
	return data
end

--- Parse tags from a request spec.
--- The parser stores `# @tag a,b` in `spec.opts.tag`; older specs may
--- carry a `spec.directives` list instead. Both shapes are accepted.
---@param spec table
---@return string[]
function M.parse_tags(spec)
	local tags = {}
	local function add(raw)
		if type(raw) ~= "string" then
			return
		end
		for tag in raw:gmatch("[^,]+") do
			tag = vim.trim(tag)
			if tag ~= "" then
				table.insert(tags, tag)
			end
		end
	end
	if spec.directives then
		for _, dir in ipairs(spec.directives) do
			if dir.name == "tag" then
				add(dir.value)
			end
		end
	end
	if spec.opts then
		add(spec.opts.tag)
	end
	return tags
end

return M