--- Code snippet generation (Insomnia's "copy as …"): curl, python-requests,
--- javascript fetch, go net/http. All specs are var-substituted first.
local client = require("tuiter.client")

local M = {}

---@param lang string "curl" | "python" | "js" | "go"
function M.generate(lang, spec, curl_opts)
	if lang == "curl" then
		return client.curl_command(spec, curl_opts)
	elseif lang == "python" then
		return M.python(spec)
	elseif lang == "js" then
		return M.js(spec)
	elseif lang == "go" then
		return M.go(spec)
	end
	return nil
end

local function prepare(spec)
	local url = client.substitute(spec.url, spec.vars)
	local headers = {}
	for k, v in pairs(spec.headers or {}) do
		headers[k] = client.substitute(v, spec.vars)
	end
	local body = spec.body and client.substitute(spec.body, spec.vars) or nil
	return url, headers, body
end

local function is_json_body(body)
	if not body then
		return false
	end
	local ok = pcall(vim.json.decode, body)
	return ok
end

local header_pairs = function(headers)
	local out = {}
	for k, v in pairs(headers) do
		out[#out + 1] = { k, v }
	end
	table.sort(out, function(a, b)
		return a[1] < b[1]
	end)
	return out
end

function M.python(spec)
	local url, headers, body = prepare(spec)
	local json_body = is_json_body(body)
	local lines = { "import requests" }
	if json_body then
		lines[#lines + 1] = "import json"
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = ("url = %q"):format(url)
	if body then
		if json_body then
			local ok, data = pcall(vim.json.decode, body)
			lines[#lines + 1] = ("payload = %s"):format(ok and vim.json.encode(data) or "None")
		else
			lines[#lines + 1] = ("payload = %q"):format(body)
		end
	end
	local hs = header_pairs(headers)
	lines[#lines + 1] = "headers = {"
	for _, h in ipairs(hs) do
		lines[#lines + 1] = ("    %q: %q,"):format(h[1], h[2])
	end
	lines[#lines + 1] = "}"
	lines[#lines + 1] = ""
	local call = ("resp = requests.request(%q, url, headers=headers"):format(spec.method)
	if body then
		call = call .. (json_body and ", data=json.dumps(payload)" or ", data=payload")
	end
	lines[#lines + 1] = call .. ")"
	lines[#lines + 1] = "print(resp.status_code, resp.text)"
	return table.concat(lines, "\n")
end

function M.js(spec)
	local url, headers, body = prepare(spec)
	local json_body = is_json_body(body)
	local lines = { ("const url = %q;"):format(url), "const options = {" }
	lines[#lines + 1] = ("  method: %q,"):format(spec.method)
	local hs = header_pairs(headers)
	lines[#lines + 1] = "  headers: {"
	for _, h in ipairs(hs) do
		lines[#lines + 1] = ("    %q: %q,"):format(h[1], h[2])
	end
	lines[#lines + 1] = "  },"
	if body then
		if json_body then
			local ok, data = pcall(vim.json.decode, body)
			if ok then
				lines[#lines + 1] = ("  body: JSON.stringify(%s),"):format(vim.json.encode(data))
			end
		else
			lines[#lines + 1] = ("  body: %q,"):format(body)
		end
	end
	lines[#lines + 1] = "};"
	lines[#lines + 1] = ""
	lines[#lines + 1] = "fetch(url, options).then(r => r.text()).then(console.log);"
	return table.concat(lines, "\n")
end

function M.go(spec)
	local url, headers, body = prepare(spec)
	local lines = {
		"package main",
		"",
		"import (",
		'\t"bytes"',
		'\t"fmt"',
		'\t"io"',
		'\t"net/http"',
		")",
		"",
		"func main() {",
		("\turl := %q"):format(url),
	}
	if body then
		local safe = body:gsub("`", '` + "`" + `')
		lines[#lines + 1] = ("\tbody := []byte(`%s`)"):format(safe)
	end
	lines[#lines + 1] = ("\treq, err := http.NewRequest(%q, url, bytes.NewBuffer(%s))"):format(
		spec.method,
		body and "body" or "nil"
	)
	lines[#lines + 1] = "\tif err != nil { panic(err) }"
	for _, h in ipairs(header_pairs(headers)) do
		lines[#lines + 1] = ("\treq.Header.Set(%q, %q)"):format(h[1], h[2])
	end
	lines[#lines + 1] = "\tresp, err := http.DefaultClient.Do(req)"
	lines[#lines + 1] = "\tif err != nil { panic(err) }"
	lines[#lines + 1] = "\tdefer resp.Body.Close()"
	lines[#lines + 1] = "\tb, _ := io.ReadAll(resp.Body)"
	lines[#lines + 1] = "\tfmt.Println(resp.StatusCode, string(b))"
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

return M
