test:
	nvim --headless -l tests/run.lua
	nvim --headless -l tests/integration.lua

format:
	stylua lua/ plugin/ ftplugin/ tests/

.PHONY: test format
