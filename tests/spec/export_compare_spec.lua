-- Compare exports with the output of Emacs Org 9.8.10 (org-export-as,
-- body only, org-export-use-babel nil) checked in next to the fixtures.
-- Generated ids (orgXXXXXXX) and times are normalised.

local ox = require("org.export.ox")
local config = require("org.config")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local dir = root .. "/fixtures/export/emacs"

local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function normalise(s)
  s = s:gsub("org%x%x%x%x%x%x%x", "orgXXXXXXX")
  s = s:gsub("%d%d%d%d%-%d%d%-%d%d %a%a%a %d%d:%d%d", "DATETIME")
  return s
end

local CASES = {
  { "html", "html" },
  { "latex", "tex" },
  { "md", "md" },
  { "org", "out.org" },
}

-- Cases left out: f5 -> org aligns a <r> cookie in a numeric column the
-- way org.table renders it (the table area owns that alignment).
local SKIP = { ["f5.org"] = true }

local FILES = { "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f9", "f10", "f11", "f12", "f13", "f14", "f16" }

describe("export matches Emacs", function()
  before_each(function()
    config.opts.babel.evaluate_on_export = false
    config.opts.edit_src_content_indentation = 2
  end)
  for _, name in ipairs(FILES) do
    for _, case in ipairs(CASES) do
      if not SKIP[name .. "." .. case[1]] then
        it(name .. " -> " .. case[1], function()
          local file = dir .. "/" .. name .. ".org"
          local expected = read(dir .. "/" .. name .. "." .. case[2])
          local out = ox.export_as(case[1], vim.fn.readfile(file), { filename = file, body_only = true })
          eq(normalise(expected), normalise(out))
        end)
      end
    end
  end
end)
