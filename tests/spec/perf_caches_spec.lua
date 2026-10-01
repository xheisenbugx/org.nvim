local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")

describe("inherited tags memo", function()
  local saved
  before_each(function()
    saved = {
      inh = config.opts.use_tag_inheritance,
      excl = config.opts.tags_exclude_from_inheritance,
    }
  end)
  after_each(function()
    config.opts.use_tag_inheritance = saved.inh
    config.opts.tags_exclude_from_inheritance = saved.excl
  end)

  it("gives the same tags when asked twice, and a list the caller may change", function()
    local buf = org_buffer({ "#+FILETAGS: :ft:", "* A :a:", "** B :b:", "*** C :c:" })
    local c = files.get_buffer(buf).headlines[3]
    local first = c:get_tags()
    eq({ "ft", "a", "b", "c" }, first)
    first[#first + 1] = "x"
    eq({ "ft", "a", "b", "c" }, c:get_tags())
  end)

  it("follows changes of use_tag_inheritance and tags_exclude_from_inheritance", function()
    local buf = org_buffer({ "#+FILETAGS: :ft:", "* A :a:", "** B :b:", "*** C :c:" })
    local c = files.get_buffer(buf).headlines[3]
    eq({ "ft", "a", "b", "c" }, c:get_tags())
    config.opts.tags_exclude_from_inheritance = { "a" }
    eq({ "ft", "b", "c" }, c:get_tags())
    config.opts.use_tag_inheritance = "^[ab]$"
    eq({ "b", "c" }, c:get_tags())
    config.opts.use_tag_inheritance = false
    eq({ "c" }, c:get_tags())
    config.opts.use_tag_inheritance = true
    config.opts.tags_exclude_from_inheritance = {}
    eq({ "ft", "a", "b", "c" }, c:get_tags())
  end)

  it("follows a parent whose tags were replaced", function()
    local buf = org_buffer({ "* A :a:", "** B :b:" })
    local file = files.get_buffer(buf)
    local a, b = file.headlines[1], file.headlines[2]
    eq({ "a", "b" }, b:get_tags())
    a.tags = { "z" }
    eq({ "z", "b" }, b:get_tags())
  end)
end)

describe("find_buffer path cache", function()
  it("finds a buffer by its new name after a rename", function()
    local buf = org_buffer({ "* Task" })
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".org")
    local before = vim.api.nvim_buf_get_name(buf)
    eq(buf, utils.find_buffer(before))
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".org")
    local after = vim.api.nvim_buf_get_name(buf)
    eq(buf, utils.find_buffer(after))
    eq(nil, utils.find_buffer(before))
  end)

  it("finds a buffer through a symlink, also once its file is created", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local real = dir .. "/real.org"
    local link = dir .. "/link.org"
    local buf = org_buffer({ "* Task" })
    vim.api.nvim_buf_set_name(buf, real)
    -- not on disk yet: the symlink can't resolve to it
    eq(nil, utils.find_buffer(link))
    vim.cmd("silent write")
    vim.uv.fs_symlink(real, link)
    eq(buf, utils.find_buffer(link))
    -- created outside Vim: looked up again after a shell command
    local other = org_buffer({ "* Other" })
    vim.api.nvim_buf_set_name(other, dir .. "/other.org")
    local other_link = dir .. "/other-link.org"
    eq(nil, utils.find_buffer(other_link))
    vim.fn.writefile({ "* Other" }, dir .. "/other.org")
    vim.uv.fs_symlink(dir .. "/other.org", other_link)
    vim.api.nvim_exec_autocmds("ShellCmdPost", {})
    eq(other, utils.find_buffer(other_link))
  end)
end)

describe("agenda sorting caches", function()
  it("sets list timestamps with and without a precomputed kind", function()
    local items = require("org.agenda.items")
    local buf = org_buffer({ "* TODO A", "SCHEDULED: <2026-10-05 Mon>" })
    local hl = files.get_buffer(buf).headlines[1]
    local strategy = { "scheduled-up" }
    local a, b = { headline = hl, type = "todo" }, { headline = hl, type = "todo" }
    items.set_list_timestamp(a, strategy)
    items.set_list_timestamp(b, strategy, items.list_timestamp_kind(strategy))
    eq(" scheduled", a.ts_type:sub(-10))
    eq(a.ts_date, b.ts_date)
    eq(a.ts_type, b.ts_type)
    eq(nil, items.list_timestamp_kind({ "priority-down" }))
  end)

  it("sorts by category with repeated categories", function()
    local items = require("org.agenda.items")
    local list = {}
    for i, c in ipairs({ "b", "a", "c", "a", "b", "a" }) do
      list[i] = { category = c, order = i }
    end
    local sorted = items.sort(list, { "category-up" })
    local cats = vim.tbl_map(function(x)
      return x.category
    end, sorted)
    eq({ "a", "a", "a", "b", "b", "c" }, cats)
    -- stable for equal keys
    eq({ 2, 4, 6 }, { sorted[1].order, sorted[2].order, sorted[3].order })
  end)
end)
