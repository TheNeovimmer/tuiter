--- :checkhealth tuiter — environment probe for the plugin.
local M = {}

local function writable(dir)
	if vim.fn.mkdir(dir, "p") ~= 1 then
		return false, "cannot create " .. dir
	end
	local probe = dir .. "/.tuiter-health-probe"
	local ok = pcall(vim.fn.writefile, { "ok" }, probe)
	if ok then
		vim.fn.delete(probe)
	end
	return ok, ok and nil or ("cannot write to " .. dir)
end

function M.check()
	vim.health.start("tuiter")

	-- Neovim version (vim.system, window titles, vim.json)
	if vim.fn.has("nvim-0.10") == 1 then
		vim.health.ok(string.format("Neovim >= 0.10 (vim.system / window titles) — found %s", vim.version()))
	else
		vim.health.error(
			"Neovim >= 0.10 required",
			"tuiter uses vim.system(), window titles and vim.json — upgrade Neovim"
		)
	end

	-- curl
	if vim.fn.executable("curl") == 1 then
		local ver = (vim.fn.system({ "curl", "--version" }):match("curl ([%d.]+)")) or "?"
		vim.health.ok(string.format("curl %s found on PATH", ver))
	else
		vim.health.error(
			"curl not found on PATH",
			"requests go out via curl — install it (apt install curl / brew install curl)"
		)
	end

	-- data dir (history, favorites, oauth cache, cookie jars)
	local data = vim.fn.stdpath("data") .. "/tuiter"
	local ok, err = writable(data)
	if ok then
		vim.health.ok(string.format("data dir writable (%s)", data))
	else
		vim.health.error(
			"data dir not writable: " .. (err or "?"),
			"history/favorites/oauth/cookies are persisted under " .. data
		)
	end

	-- cookie jar dir (created lazily by client.lua)
	if vim.fn.executable("curl") == 1 then
		local okc, cerr = writable(data .. "/cookies")
		if okc then
			vim.health.ok("cookie jar dir writable")
		else
			vim.health.warn("cookie jar dir: " .. (cerr or "?"), "set opts.curl.cookie_jar = false to disable cookies")
		end
	end

	-- optional niceties
	if vim.fn.executable("jq") == 0 then
		vim.health.info("jq not found — the `J` jq-filter in the response window will be unavailable")
	end
end

return M
