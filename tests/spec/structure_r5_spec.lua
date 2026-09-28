-- Structure editing commands added for Emacs Org 9.8.10 parity:
-- org-edit-headline, org-insert-todo-subheading, org-convert-to-odd-levels
-- and org-convert-to-oddeven-levels. Expectations come from Emacs 9.8.10.
local utils = require("org.utils")
vim.g.org_test = true

local function with_stub(tbl, key, fn, body)
  local orig = tbl[key]
  tbl[key] = fn
  local ok, err = pcall(body)
  tbl[key] = orig
  if not ok then
    error(err, 0)
  end
end

local function yes(body)
  with_stub(utils, "confirm", function()
    return true
  end, body)
end

describe("edit_headline", function()
  it("replaces the title, keeping keyword, priority and tags", function()
    local buf = org_buffer({ "* TODO [#A] Old title  :tag:", "body" }, { 2, 0 })
    require("org.structure").edit_headline("A much longer new title")
    eq({ "* TODO [#A] A much longer new title                                     :tag:", "body" }, buf_lines(buf))
  end)

  it("adds a title to an empty headline", function()
    local buf = org_buffer({ "* TODO :tag:" }, { 1, 0 })
    require("org.structure").edit_headline("New")
    eq({ "* TODO New                                                              :tag:" }, buf_lines(buf))
  end)

  it("edits COMMENT as part of the title and trims", function()
    local buf = org_buffer({ "* COMMENT Old" }, { 1, 0 })
    require("org.structure").edit_headline("  New  ")
    eq({ "* New" }, buf_lines(buf))
  end)

  it("prompts with the old title", function()
    local buf = org_buffer({ "** DONE Title :a:" }, { 1, 0 })
    local seen
    with_stub(utils, "input", function(opts)
      seen = opts
      return "Changed"
    end, function()
      require("org.actions").run("edit_headline")
    end)
    eq("Edit: ", seen.prompt)
    eq("Title", seen.default)
    ok(buf_lines(buf)[1]:match("^%*%* DONE Changed%s+:a:$"))
  end)
end)

describe("insert_todo_subheading", function()
  it("inserts a demoted TODO heading after the headline line", function()
    local buf = org_buffer({ "* TODO A", "body", "* B" }, { 1, 0 })
    require("org.structure").insert_todo_subheading()
    vim.cmd("stopinsert")
    eq({ "* TODO A", "** TODO ", "body", "* B" }, buf_lines(buf))
  end)

  it("uses the first keyword after a done sibling", function()
    local buf = org_buffer({ "* DONE A" }, { 1, 0 })
    require("org.structure").insert_todo_subheading()
    vim.cmd("stopinsert")
    eq({ "* DONE A", "** TODO " }, buf_lines(buf))
  end)

  it("inserts an indented checkbox item on an item", function()
    local buf = org_buffer({ "* TODO A", "- item" }, { 2, 0 })
    require("org.structure").insert_todo_subheading()
    vim.cmd("stopinsert")
    eq({ "* TODO A", "- item", "  - [ ] " }, buf_lines(buf))
  end)
end)

describe("level conversion", function()
  it("convert_to_odd_levels", function()
    local buf = org_buffer({ "* A", "** B :x:", "text", "*** C", "**** D", "* E" }, { 1, 0 })
    yes(function()
      require("org.structure").convert_to_odd_levels()
    end)
    eq({
      "* A",
      "*** B                                                                     :x:",
      "text",
      "***** C",
      "******* D",
      "* E",
    }, buf_lines(buf))
  end)

  it("convert_to_oddeven_levels", function()
    local buf = org_buffer({ "* A", "*** B :x:", "text", "***** C" }, { 3, 0 })
    yes(function()
      require("org.structure").convert_to_oddeven_levels()
    end)
    eq({
      "* A",
      "** B                                                                      :x:",
      "text",
      "*** C",
    }, buf_lines(buf))
    eq({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("convert_to_oddeven_levels refuses even levels", function()
    local buf = org_buffer({ "* A", "** B" }, { 1, 0 })
    local msg
    with_stub(utils, "error", function(m)
      msg = m
    end, function()
      yes(function()
        require("org.structure").convert_to_oddeven_levels()
      end)
    end)
    eq("Not all levels are odd in this file.  Conversion not possible", msg)
    eq({ "* A", "** B" }, buf_lines(buf))
  end)

  it("asks before converting", function()
    local buf = org_buffer({ "* A", "** B" }, { 1, 0 })
    with_stub(utils, "confirm", function()
      return false
    end, function()
      require("org.structure").convert_to_odd_levels()
    end)
    eq({ "* A", "** B" }, buf_lines(buf))
  end)
end)
