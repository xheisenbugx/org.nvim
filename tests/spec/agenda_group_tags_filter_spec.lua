-- Group tags in the agenda tag filter (org-agenda-filter-expand-tags):
-- filtering by a group tag keeps the entries with any of its members.
local config = require("org.config")
local utils = require("org.utils")
local view = require("org.agenda.view")
local agenda = require("org.agenda")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/g.org"

local lines = {
  "#+TAGS: [ Work : Lab Office ]",
  "#+TAGS: [ Lab : Bench ]",
  "#+TAGS: [ Proj : {P@.+} ]",
  "* TODO In the lab :Lab:",
  "* TODO At the office :Office:",
  "* TODO At the bench :Bench:",
  "* TODO Tagged Work :Work:",
  "* TODO At home :Home:",
  "* TODO Project :P@one:",
}

local function titles()
  local out = {}
  for _, it in pairs(view.state.line_items) do
    out[#out + 1] = it.title
  end
  table.sort(out)
  return out
end

describe("agenda tag filter with group tags", function()
  before_each(function()
    utils.writefile(path, lines)
    local b = utils.find_buffer(path)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    config.setup({ agenda_files = { path }, org_directory = dir })
    agenda.open({ blocks = { { type = "todo" } } })
  end)
  after_each(function()
    pcall(view.quit, true)
    -- the file's #+TAGS groups would apply to later match specs while it is
    -- an agenda file
    local b = utils.find_buffer(path)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    config.setup({})
  end)

  it("expands a group tag into its members, recursively", function()
    view.set_tag_filter({ "+Work" })
    eq({ "At the bench", "At the office", "In the lab", "Tagged Work" }, titles())
    view.set_tag_filter({ "+Lab" })
    eq({ "At the bench", "In the lab" }, titles())
  end)

  it("excludes every member with -Group", function()
    view.set_tag_filter({ "-Work" })
    eq({ "At home", "Project" }, titles())
  end)

  it("expands regexp members", function()
    view.set_tag_filter({ "+Proj" })
    eq({ "Project" }, titles())
  end)

  it("recognizes group tags in filter strings", function()
    local f = view.parse_filter("+Proj")
    eq({ "+Proj" }, f.tag)
  end)

  it("matches literally when group_tags is off", function()
    config.opts.group_tags = false
    view.set_tag_filter({ "+Work" })
    eq({ "Tagged Work" }, titles())
    config.opts.group_tags = true
  end)
end)
