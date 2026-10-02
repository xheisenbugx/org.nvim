-- Paths written in a document must never reach vim.fn.expand(), which runs
-- `backticks` as shell commands.
describe("document paths", function()
  local marker

  before_each(function()
    marker = vim.fn.tempname() .. "-pwned"
  end)

  it("expand_vars expands ~ and variables but never runs backticks", function()
    local utils = require("org.utils")
    eq(utils.home() .. "/x", utils.expand_vars("~/x"))
    vim.env.ORG_EXPAND_SPEC = "/v"
    eq("/v/a", utils.expand_vars("$ORG_EXPAND_SPEC/a"))
    eq("/v/a", utils.expand_vars("${ORG_EXPAND_SPEC}/a"))
    eq("rel/a", utils.expand_vars("rel/a"))
    local p = "/tmp/`touch " .. marker .. "`/a.bib"
    eq(p, utils.expand_vars(p))
    eq(nil, vim.uv.fs_stat(marker))
  end)

  it("resolving an absolute bibliography path runs nothing", function()
    local p = "/tmp/`touch " .. marker .. "`/refs.bib"
    require("org.export.cite").bibliography_path(p, {})
    eq(nil, vim.uv.fs_stat(marker))
  end)

  it("an absolute image link in an export runs nothing", function()
    require("org.export.ox").file_uri("/tmp/`touch " .. marker .. "`/a.png")
    eq(nil, vim.uv.fs_stat(marker))
  end)
end)
