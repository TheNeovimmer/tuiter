--- OAuth2 token management: bearer, client-credentials and refresh-token
--- flows. Tokens are cached in stdpath("data")/tuiter/oauth.json keyed by
--- (token_url, client_id, scope, refresh_token) with expiry.
---
--- Directives:
---   # @auth bearer TOKEN
---   # @auth oauth2 token_url=.. client_id=.. client_secret=.. scope=..
---   # @auth refresh token_url=.. client_id=.. client_secret=.. refresh_token=..
local M = {}

-- created at module load: mkdir is illegal inside vim.system callbacks
local OAUTH_DIR = vim.fn.stdpath("data") .. "/tuiter"
pcall(vim.fn.mkdir, OAUTH_DIR, "p")

local function file()
	return OAUTH_DIR .. "/oauth.json"
end

local function load()
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

local function save(cache)
	pcall(vim.fn.writefile, { vim.json.encode(cache) }, file())
end

--- Stable cache key for an auth table.
local function key(auth)
	return table.concat({
		auth.type or "",
		auth.token_url or "",
		auth.client_id or "",
		auth.scope or "",
		auth.refresh_token or "",
	}, "|")
end

--- Fetch a token from the token_url via curl (client_credentials or
--- refresh_token grant). cb(access_token or nil, refresh_token or nil, expires_in or nil).
local function fetch(auth, curl_opts, cb)
	if not auth.token_url then
		vim.notify("Tuiter: # @auth " .. auth.type .. " is missing token_url", vim.log.levels.WARN, { title = "Tuiter" })
		cb(nil)
		return
	end
	local grant = auth.type == "refresh" and "refresh_token" or "client_credentials"
	local args = {
		"curl",
		"-sS",
		"--max-time",
		tostring(curl_opts.timeout or 30),
		"-u",
		auth.client_id .. ":" .. (auth.client_secret or ""),
		"-d",
		"grant_type=" .. grant,
	}
	if auth.scope and auth.scope ~= "" then
		args[#args + 1] = "-d"
		args[#args + 1] = "scope=" .. auth.scope
	end
	if grant == "refresh_token" then
		args[#args + 1] = "-d"
		args[#args + 1] = "refresh_token=" .. (auth.refresh_token or "")
	end
	args[#args + 1] = auth.token_url
	vim.system(args, { text = true }, function(out)
		local ok, data = pcall(vim.json.decode, out.stdout)
		if not ok or not data or not data.access_token then
			vim.schedule(function()
				vim.notify(
					"Tuiter: token fetch failed (" .. auth.token_url .. "): " .. (out.stdout or out.stderr or "no response"),
					vim.log.levels.ERROR,
					{ title = "Tuiter" }
				)
			end)
			cb(nil)
			return
		end
		cb(data.access_token, data.refresh_token, data.expires_in)
	end)
end

--- Get a usable token for `auth`. Cached tokens are reused until ~30s
--- before expiry. cb(token or nil).
function M.ensure_token(auth, _cwd, curl_opts, cb)
	if auth.type == "bearer" then
		cb(auth.token, false)
		return
	end
	if auth.type ~= "oauth2" and auth.type ~= "refresh" then
		cb(nil)
		return
	end
	local cache = load()
	local k = key(auth)
	local hit = cache[k]
	if hit and hit.token and (hit.expires_at or math.huge) > os.time() + 30 then
		cb(hit.token, false)
		return
	end
	fetch(auth, curl_opts, function(token, refresh_token, expires_in)
		if not token then
			cb(nil)
			return
		end
		cache[k] = {
			token = token,
			expires_at = os.time() + (tonumber(expires_in) or 3600),
			refresh_token = refresh_token or auth.refresh_token,
		}
		save(cache)
		cb(token, true)
	end)
end

--- Drop the cached token for `auth` (e.g. after a 401 so the next request
--- re-fetches with the refresh token).
function M.invalidate(auth)
	local cache = load()
	cache[key(auth)] = nil
	save(cache)
end

return M
