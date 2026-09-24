.PHONY: test lint

test:
	nvim --headless -u tests/minimal_init.lua -l tests/run.lua $(SPEC)

lint:
	stylua --check lua plugin ftplugin syntax tests
