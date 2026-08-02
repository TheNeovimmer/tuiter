STYLUA ?= stylua

test:
	nvim --headless -l tests/run.lua
	nvim --headless -l tests/integration.lua
	nvim --headless -l tests/e2e.lua

# requires the local LazyVim config + a working network
smoke:
	nvim --headless -u $(HOME)/.config/nvim/init.lua -c "luafile tests/lazyvim_smoke.lua"

format:
	$(STYLUA) lua/ plugin/ ftplugin/ tests/

lint:
	$(STYLUA) --check lua/ plugin/ ftplugin/ tests/

.PHONY: test format lint
