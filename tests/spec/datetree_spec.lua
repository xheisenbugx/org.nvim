-- org-datetree-add-timestamp and org-datetree-cleanup. Expected buffers come
-- from Emacs 9.8.10 (probes with org-datetree-find-date-create and
-- org-datetree-cleanup).
local capture = require("org.capture")
local config = require("org.config")
local date = require("org.date")
vim.g.org_test = true

local function D(y, m, d)
  return date.Date.new({ year = y, month = m, day = d })
end

describe("datetree_add_timestamp (org-datetree-add-timestamp)", function()
  it("adds nothing by default", function()
    config.setup({})
    local buf = org_buffer({ "" }, { 1, 0 })
    capture.ensure_datetree(buf, nil, D(2026, 9, 25))
    eq({ "", "* 2026", "** 2026-09 September", "*** 2026-09-25 Friday" }, buf_lines(buf))
  end)

  it("stamps new day nodes only, inactive", function()
    config.setup({ datetree_add_timestamp = "inactive" })
    local buf = org_buffer({ "" }, { 1, 0 })
    capture.ensure_datetree(buf, nil, D(2026, 9, 25))
    capture.ensure_datetree(buf, nil, D(2026, 9, 25))
    capture.ensure_datetree(buf, nil, D(2026, 9, 26))
    eq({
      "",
      "* 2026",
      "** 2026-09 September",
      "*** 2026-09-25 Friday",
      "[2026-09-25 Fri]",
      "*** 2026-09-26 Saturday",
      "[2026-09-26 Sat]",
    }, buf_lines(buf))
  end)

  it("indents an active stamp with adapt_indentation, and skips month trees", function()
    config.setup({ datetree_add_timestamp = "active", adapt_indentation = true })
    local buf = org_buffer({ "" }, { 1, 0 })
    capture.ensure_datetree(buf, nil, D(2026, 9, 25))
    eq({ "", "* 2026", "** 2026-09 September", "*** 2026-09-25 Friday", "    <2026-09-25 Fri>" }, buf_lines(buf))
    config.setup({ datetree_add_timestamp = "active" })
    buf = org_buffer({ "" }, { 1, 0 })
    capture.ensure_datetree(buf, nil, D(2026, 9, 25), "month")
    eq({ "", "* 2026", "** 2026-09 September" }, buf_lines(buf))
  end)
end)

describe("datetree_cleanup (org-datetree-cleanup)", function()
  before_each(function()
    config.setup({})
  end)

  it("moves entries under the day of their time stamp", function()
    local buf = org_buffer({
      "* 2026",
      "** 2026-09 September",
      "*** 2026-09-25 Friday",
      "**** Entry A",
      "<2026-09-27 Sun>",
      "**** Entry B",
      "<2026-09-25 Fri>",
    }, { 1, 0 })
    require("org.datetree").cleanup(buf)
    eq({
      "* 2026",
      "** 2026-09 September",
      "*** 2026-09-25 Friday",
      "**** Entry B",
      "<2026-09-25 Fri>",
      "*** 2026-09-27 Sunday",
      "**** Entry A",
      "<2026-09-27 Sun>",
    }, buf_lines(buf))
  end)

  it("appends to an existing day, skips range ends, inactive stamps and non-tree entries", function()
    local buf = org_buffer({
      "* 2026",
      "** 2026-09 September",
      "*** 2026-09-25 Friday",
      "**** Entry A",
      "<2026-09-27 Sun>",
      "body",
      "**** Entry D",
      "[2026-10-02 Fri]",
      "**** Entry E",
      "<2026-09-25 Fri 10:00>--<2026-09-28 Mon>",
      "*** 2026-09-27 Sunday",
      "**** Existing",
      "* Other",
      "<2026-01-01 Thu>",
      "** Entry F",
      "<2026-01-02 Fri>",
    }, { 1, 0 })
    require("org.datetree").cleanup(buf)
    eq({
      "* 2026",
      "** 2026-09 September",
      "*** 2026-09-25 Friday",
      "**** Entry D",
      "[2026-10-02 Fri]",
      "**** Entry E",
      "<2026-09-25 Fri 10:00>--<2026-09-28 Mon>",
      "*** 2026-09-27 Sunday",
      "**** Existing",
      "**** Entry A",
      "<2026-09-27 Sun>",
      "body",
      "* Other",
      "<2026-01-01 Thu>",
      "** Entry F",
      "<2026-01-02 Fri>",
    }, buf_lines(buf))
  end)

  it("leaves SCHEDULED and DEADLINE stamps alone (intentional difference)", function()
    local lines = {
      "* 2026",
      "** 2026-09 September",
      "*** 2026-09-25 Friday",
      "**** Entry A",
      "DEADLINE: <2026-09-27 Sun> SCHEDULED: <2026-09-20 Sun>",
    }
    local buf = org_buffer(lines, { 1, 0 })
    require("org.datetree").cleanup(buf)
    eq(lines, buf_lines(buf))
  end)
end)
