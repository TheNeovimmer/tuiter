--- Code snippet generation (Insomnia's "copy as …"): curl, python-requests,
--- javascript/typescript fetch, go net/http, rust reqwest, php curl,
--- graphql fetch. All specs are var-substituted first.
local client = require("tuiter.client")

local M = {}

---@param lang string "curl" | "python" | "js" | "ts" | "go" | "rust" | "php" | "graphql"
function M.generate(lang, spec, curl_opts)
	if lang == "curl" then
		return client.curl_command(spec, curl_opts)
	elseif lang == "python" then
		return M.python(spec)
	elseif lang == "js" then
		return M.js(spec)
	elseif lang == "ts" then
		return M.ts(spec)
	elseif lang == "go" then
		return M.go(spec)
	elseif lang == "rust" then
		return M.rust(spec)
	elseif lang == "php" then
		return M.php(spec)
	elseif lang == "graphql" then
		return M.graphql(spec)
	end
	return nil
end

local function prepare(spec)
	local url = client.resolve_url(spec)
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

local function js_fetch(spec, typed)
	local url, headers, body = prepare(spec)
	local json_body = is_json_body(body)
	local decl = typed and "const url: string" or "const url"
	local lines = { ("%s = %q;"):format(decl, url), "const options = {" }
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

function M.js(spec)
	return js_fetch(spec, false)
end

function M.ts(spec)
	return js_fetch(spec, true)
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

function M.rust(spec)
	local url, headers, body = prepare(spec)
	local lines = {
		"use reqwest; // cargo add reqwest tokio --features tokio/full",
		"",
		"#[tokio::main]",
		"async fn main() -> Result<(), Box<dyn std::error::Error>> {",
		"\tlet client = reqwest::Client::new();",
	}
	lines[#lines + 1] = ("\tlet resp = client.%s(%q)"):format(spec.method:lower(), url)
	for _, h in ipairs(header_pairs(headers)) do
		lines[#lines + 1] = ("\t\t.header(%q, %q)"):format(h[1], h[2])
	end
	if body then
		lines[#lines + 1] = ("\t\t.body(%q.to_string())"):format(body:gsub("%q", "\\%q"))
	end
	lines[#lines + 1] = "\t\t.send()"
	lines[#lines + 1] = "\t\t.await?;"
	lines[#lines + 1] = '\tprintln!("{} {}", resp.status(), resp.text().await?);'
	lines[#lines + 1] = "\tOk(())"
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

function M.php(spec)
	local url, headers, body = prepare(spec)
	local lines =
		{ '$ch = curl_init("' .. url .. '");', 'curl_setopt($ch, CURLOPT_CUSTOMREQUEST, "' .. spec.method .. '");' }
	if body then
		lines[#lines + 1] = 'curl_setopt($ch, CURLOPT_POSTFIELDS, "' .. body:gsub('"', '\\"') .. '");'
	end
	local hdrs = {}
	for _, h in ipairs(header_pairs(headers)) do
		hdrs[#hdrs + 1] = '"' .. h[1] .. ": " .. h[2] .. '"'
	end
	lines[#lines + 1] = "curl_setopt($ch, CURLOPT_HTTPHEADER, array(" .. table.concat(hdrs, ", ") .. "));"
	lines[#lines + 1] = "curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);"
	lines[#lines + 1] = "$response = curl_exec($ch);"
	lines[#lines + 1] = "$status = curl_getinfo($ch, CURLINFO_HTTP_CODE);"
	lines[#lines + 1] = "curl_close($ch);"
	lines[#lines + 1] = 'echo $status . " " . $response;'
	return table.concat(lines, "\n")
end

--- For GraphQL operations: extract the query text from the JSON body
--- tuiter sends, and emit a clean JS fetch with the operation separated.
function M.graphql(spec)
	local url, headers, body = prepare(spec)
	local query, variables = nil, nil
	if body then
		local ok, data = pcall(vim.json.decode, body)
		if ok and type(data) == "table" then
			query = data.query
			variables = data.variables
		end
	end
	if not query then
		return M.js(spec)
	end
	local lines = { ("const url = %q;"):format(url), ("const query = %q;"):format(query) }
	if variables then
		lines[#lines + 1] = ("const variables = %s;"):format(vim.json.encode(variables))
	end
	lines[#lines + 1] = "fetch(url, { method: 'POST', headers: " .. vim.json.encode(headers) .. ", body: JSON.stringify({"
	lines[#lines + 1] = "  query,"
	if variables then
		lines[#lines + 1] = "  variables,"
	end
	lines[#lines + 1] = "}) }).then(r => r.text()).then(console.log);"
	return table.concat(lines, "\n")
end

return M
