--- tuiter.icons: central glyph table with nerd-font / ASCII fallback.
--- Mode is "auto" (default: portable unicode glyphs, today's look),
--- "nerd" (real Nerd Font codepoints), or "ascii" (pure ASCII for
--- minimal terminals). Set via `setup({ icons = ... })` or
--- `vim.g.tuiter_icons`. `get()` returns the active icon set.
local M = {}

-- Portable unicode: renders in (almost) every font. This is the default.
local DEFAULT = {
	ok = "✓",
	err = "✗",
	star = "★",
	star_off = "☆",
	running = "↻",
	skip = "⏭",
	warn = "⚠",
	sep = "─",
	arrow = "↵",
}

-- Nerd Fonts (FontAwesome codepoints, written as UTF-8 byte escapes so the
-- file stays pure ASCII). Only use with a Nerd Font active.
local NERD = {
	ok = "\239\128\140", -- U+F00C fa-check
	err = "\239\128\141", -- U+F00D fa-times
	star = "\239\128\133", -- U+F005 fa-star
	star_off = "\239\128\134", -- U+F006 fa-star-o
	running = "\239\128\161", -- U+F021 fa-refresh
	skip = "\239\129\142", -- U+F04E fa-fast-forward
	warn = "\239\129\177", -- U+F071 fa-warning
	sep = "─",
	arrow = "↵",
}

local ASCII = {
	ok = "v",
	err = "x",
	star = "*",
	star_off = "-",
	running = ">",
	skip = "-",
	warn = "!",
	sep = "-",
	arrow = "->",
}

local override = nil

---@param mode? "auto"|"nerd"|"ascii"
function M.set(mode)
	override = mode
end

---@return "auto"|"nerd"|"ascii" the configured mode
function M.configured()
	return override or vim.g.tuiter_icons or "auto"
end

---@return boolean whether a Nerd Font looks active (for auto-hints)
function M.has_nerd_font()
	return vim.g.nerdfont == true or (vim.o.guifont and vim.o.guifont:lower():find("nerd")) or false
end

---@return table the active icon set
function M.get()
	local want = M.configured()
	if want == "nerd" then
		return NERD
	end
	if want == "ascii" then
		return ASCII
	end
	return DEFAULT
end

return M
