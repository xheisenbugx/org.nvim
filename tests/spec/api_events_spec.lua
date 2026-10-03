-- OrgTagsChanged (org-after-tags-change-hook) with handlers that edit the
-- buffer: the command doesn't lose track of its headlines.
local api = require("org.api")
local config = require("org.config")
local tags = require("org.tags")
vim.g.org_test = true

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.fs.normalize(vim.fn.resolve(dir))
end

local function setup(dir, extra)
  config.setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    agenda_files = { dir },
    todo_keywords = { "TODO", "WAIT", "|", "DONE" },
    id = { locations_file = dir .. "/ids.json" },
    tags_column = 0,
  }, extra or {}))
  require("org.id")._reset()
end

--- Collect the data of every `event` until the test ends; `fn(data)` runs
--- for each, as a handler.
local listeners = {}
local function listen(event, fn)
  local got = {}
  listeners[#listeners + 1] = api.on(event, function(data)
    got[#got + 1] = data
    if fn then
      fn(data, #got)
    end
  end)
  return got
end

--- { lnum, from, to } of each OrgTagsChanged event.
local function changes(events)
  return vim.tbl_map(function(d)
    return { d.lnum, d.from, d.to }
  end, events)
end

describe("org.api events", function()
  local dir

  before_each(function()
    dir = tmpdir()
    setup(dir)
  end)

  after_each(function()
    for _, id in ipairs(listeners) do
      api.off(id)
    end
    listeners = {}
    config.setup({})
  end)

  describe("OrgTagsChanged", function()
    it("follows the region's headlines when a handler moves them", function()
      local buf = org_buffer({ "* A", "* B :b:", "text", "text", "* C :c:" }, { 1, 0 })
      local events = listen("OrgTagsChanged", function(data)
        local h = api.headline_at({ bufnr = data.bufnr, lnum = data.lnum })
        ok(h:set_property("TAGS_CHANGED", "today"))
      end)
      eq(3, tags.change_tag_in_region(buf, 1, 5, "add", "y"))
      local drawer = { ":PROPERTIES:", ":TAGS_CHANGED: today", ":END:" }
      eq(
        vim.iter({ "* A :y:", drawer, "* B :b:y:", drawer, "text", "text", "* C :c:y:", drawer }):flatten():totable(),
        buf_lines(buf)
      )
      eq({ { 1, {}, { "y" } }, { 5, { "b" }, { "b", "y" } }, { 11, { "c" }, { "c", "y" } } }, changes(events))
    end)

    it("reads the tags a handler changed before changing them", function()
      local buf = org_buffer({ "* A", "* B :b:" }, { 1, 0 })
      -- a handler that tags the next headline too
      local events = listen("OrgTagsChanged", function(data)
        if data.lnum == 1 then
          tags.toggle_tag({ bufnr = data.bufnr, lnum = 2 }, "z")
        end
      end)
      eq(2, tags.change_tag_in_region(buf, 1, 2, "add", "y"))
      eq({ "* A :y:", "* B :b:z:y:" }, buf_lines(buf))
      eq({ { 1, {}, { "y" } }, { 2, { "b" }, { "b", "z" } }, { 2, { "b", "z" }, { "b", "z", "y" } } }, changes(events))
    end)
  end)
end)
