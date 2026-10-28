-- `make coverage`: runs the `org` command line (lua/org/extensions/cli/main.lua)
-- like bin/org does, counting its lines too (tests/coverage.lua). The specs
-- start bin/org in its own Neovim, which `make coverage` would otherwise not
-- see; tests/minimal_init.lua points those commands here instead.
--
--   nvim --headless -l tests/cli_coverage.lua [org arguments...]
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local cov = dofile(root .. "/tests/coverage.lua")
cov.start(vim.env.ORG_COVERAGE_DIR)
-- main.lua ends with os.exit(code): write the counts first
local exit = os.exit
os.exit = function(...)
  cov.write()
  return exit(...)
end
dofile(root .. "/lua/org/extensions/cli/main.lua")
cov.write()
