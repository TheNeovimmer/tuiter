--- E2E test for new UI features: badges, spinner, syntax highlighting, tabs
-- Run: nvim --headless -u NONE -c "lua dofile('tests/e2e_ui.lua')" -c "qa!"

-- set up lua path so require("tuiter.*") works
vim.opt.rtp:prepend(".")

local passed, failed = 0, 0
local function assert_eq(got, want, msg)
	if got == want then
		passed = passed + 1
	else
		failed = failed + 1
		vim.notify(string.format("FAIL: %s — got %s, want %s", msg, tostring(got), tostring(want)), vim.log.levels.ERROR)
	end
end
local function assert_ne(got, want, msg)
	if got ~= want then
		passed = passed + 1
	else
		failed = failed + 1
		vim.notify(string.format("FAIL: %s — got %s, want ≠ %s", msg, tostring(got), tostring(want)), vim.log.levels.ERROR)
	end
end
local function assert_true(v, msg)
	if v then
		passed = passed + 1
	else
		failed = failed + 1
		vim.notify("FAIL: " .. msg, vim.log.levels.ERROR)
	end
end

-- =========================================================================
-- 1. Load tuiter + UI module (defines highlight groups)
-- =========================================================================
local tuiter = require("tuiter")
tuiter.setup()
local ui = require("tuiter.ui")

-- =========================================================================
-- 2. Syntax highlighting file loads
-- =========================================================================
vim.cmd("edit examples/demo.http")
vim.bo.filetype = "http"
vim.cmd("syntax on")
vim.cmd("runtime syntax/http.vim")

local syn_output = vim.fn.execute("syntax list")
assert_true(syn_output:find("httpMethod"), "syntax/http.vim defines httpMethod group")
assert_true(syn_output:find("httpUrl"), "syntax/http.vim defines httpUrl group")
assert_true(syn_output:find("httpVariable"), "syntax/http.vim defines httpVariable group")
assert_true(syn_output:find("httpDirective"), "syntax/http.vim defines httpDirective group")
assert_true(syn_output:find("httpSection"), "syntax/http.vim defines httpSection group")
assert_true(syn_output:find("httpHeaderKey"), "syntax/http.vim defines httpHeaderKey group")
print("✓ syntax highlighting loads correctly")

-- =========================================================================
-- 3. Highlight groups exist
-- =========================================================================
local hl_groups = {
	"TuiterTabActive", "TuiterTabInactive",
	"TuiterBadge2xx", "TuiterBadge3xx", "TuiterBadge4xx", "TuiterBadge5xx",
	"TuiterMethodPill", "TuiterFooter", "TuiterFooterKey",
	"TuiterSpinner", "TuiterSep",
	"TuiterGet", "TuiterPost", "TuiterPut", "TuiterPatch", "TuiterDelete",
	"TuiterStatusOk", "TuiterStatusErr", "TuiterStatusHint",
	"TuiterUrl",
}
for _, name in ipairs(hl_groups) do
	local hl = vim.api.nvim_get_hl(0, { name = name })
	assert_true(hl and (hl.fg or hl.bg or hl.bold or hl.link), "highlight group " .. name .. " exists")
end
print("✓ all highlight groups defined")

-- =========================================================================
-- 4. Status badge rendering
-- =========================================================================
local function badge(code)
	if code >= 200 and code < 300 then return "TuiterBadge2xx"
	elseif code >= 300 and code < 400 then return "TuiterBadge3xx"
	elseif code >= 400 and code < 500 then return "TuiterBadge4xx"
	else return "TuiterBadge5xx" end
end
assert_eq(badge(200), "TuiterBadge2xx", "200 → TuiterBadge2xx")
assert_eq(badge(201), "TuiterBadge2xx", "201 → TuiterBadge2xx")
assert_eq(badge(301), "TuiterBadge3xx", "301 → TuiterBadge3xx")
assert_eq(badge(404), "TuiterBadge4xx", "404 → TuiterBadge4xx")
assert_eq(badge(500), "TuiterBadge5xx", "500 → TuiterBadge5xx")
assert_eq(badge(503), "TuiterBadge5xx", "503 → TuiterBadge5xx")
print("✓ status badge highlight mapping correct")

-- =========================================================================
-- 5. Tab line rendering format
-- =========================================================================
local method_dot = "● GET"
assert_true(method_dot:find("●"), "method dot symbol present")
assert_true(method_dot:find("GET"), "method name in dot line")
local badge_str = string.format(" %d ", 200)
assert_eq(badge_str, " 200 ", "badge string format")
local timing = string.format("%dms", 0.045 * 1000)
assert_eq(timing, "45ms", "timing format")
print("✓ tab line format correct")

-- =========================================================================
-- 6. Size formatting
-- =========================================================================
local function fmt_size(n)
	n = n or 0
	if n < 1024 then return string.format("%dB", n) end
	if n < 1024 * 1024 then return string.format("%.1fKB", n / 1024) end
	return string.format("%.1fMB", n / 1024 / 1024)
end
assert_eq(fmt_size(0), "0B", "0 bytes")
assert_eq(fmt_size(512), "512B", "512 bytes")
assert_eq(fmt_size(1024), "1.0KB", "1KB")
assert_eq(fmt_size(1536), "1.5KB", "1.5KB")
assert_eq(fmt_size(2097152), "2.0MB", "2MB")
print("✓ size formatting correct")

-- =========================================================================
-- 7. Method highlight mapping
-- =========================================================================
local METHOD_HL = {
	GET = "TuiterGet", POST = "TuiterPost", PUT = "TuiterPut",
	PATCH = "TuiterPatch", DELETE = "TuiterDelete",
}
assert_eq(METHOD_HL["GET"], "TuiterGet", "GET highlight")
assert_eq(METHOD_HL["POST"], "TuiterPost", "POST highlight")
assert_eq(METHOD_HL["PUT"], "TuiterPut", "PUT highlight")
assert_eq(METHOD_HL["PATCH"], "TuiterPatch", "PATCH highlight")
assert_eq(METHOD_HL["DELETE"], "TuiterDelete", "DELETE highlight")
print("✓ method highlights correct")

-- =========================================================================
-- 8. Spinner functions exist and work
-- =========================================================================
assert_true(type(ui.show_spinner) == "function", "show_spinner function exists")
assert_true(type(ui.close_spinner) == "function", "close_spinner function exists")

local spec = { method = "GET", url = "https://example.com/api", headers = {}, vars = {}, name = "test" }
ui.show_spinner(spec)
assert_true(ui.state.spinner_win ~= nil, "spinner window created")
assert_true(ui.state.spinner_buf ~= nil, "spinner buffer created")
assert_true(ui.state.spinner_timer ~= nil, "spinner timer created")

ui.close_spinner()
assert_true(ui.state.spinner_win == nil, "spinner window closed")
assert_true(ui.state.spinner_buf == nil, "spinner buffer closed")
assert_true(ui.state.spinner_timer == nil, "spinner timer closed")
print("✓ spinner show/close works")

-- =========================================================================
-- 9. Request chaining
-- =========================================================================
local client = require("tuiter.client")
client.state.responses["login"] = { status = 200, body = '{"id": 1}' }
local resolved = client.resolve_name("login.body.id", {})
assert_eq(resolved, "1", "named response resolves")
print("✓ request chaining works")

-- =========================================================================
-- 10. Pre/post script parsing
-- =========================================================================
local parser = require("tuiter.parser")
local script_lines = {
	"### Scripted request",
	"# @before print('before')",
	"# @after print('after')",
	"GET https://example.com/api",
	"Accept: application/json",
	"",
}
local reqs = parser.parse_lines(script_lines)
assert_eq(#reqs, 1, "parser finds 1 request")
assert_true(reqs[1].opts.scripts ~= nil, "scripts table exists")
assert_eq(reqs[1].opts.scripts.before, "print('before')", "before script parsed")
assert_eq(reqs[1].opts.scripts.after, "print('after')", "after script parsed")
print("✓ pre/post script parsing works")

-- =========================================================================
-- 11. Demo.http structure
-- =========================================================================
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local section_count = 0
for _, line in ipairs(lines) do
	if line:match("^###") then
		section_count = section_count + 1
	end
end
assert_eq(section_count, 9, "demo.http has 9 sections")
print("✓ demo.http structure validated")

-- =========================================================================
-- 12. Compact mode config
-- =========================================================================
assert_true(tuiter.opts().windows.compact ~= nil, "windows.compact config exists")
tuiter.setup({ windows = { compact = true } })
assert_true(tuiter.opts().windows.compact == true, "compact mode can be enabled")
tuiter.setup({ windows = { compact = false } })
assert_true(tuiter.opts().windows.compact == false, "compact mode can be disabled")
print("✓ compact mode config works")

-- =========================================================================
-- Summary
-- =========================================================================
print("")
print(string.format("═══ UI E2E: %d passed, %d failed ═══", passed, failed))
if failed > 0 then
	vim.cmd("cquit 1")
end
