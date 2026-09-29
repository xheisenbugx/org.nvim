-- org-beamer-mode: org-beamer-select-environment, the BEAMER_env tag
-- tracking and #+STARTUP: beamer. Expected buffers from Emacs Org 9.8.10
-- (org-beamer-select-environment with the same keys and answers).
local beamer = require("org.export.beamer_mode")
local utils = require("org.utils")
local config = require("org.config")

local function select(lines, key, answers)
  local buf = org_buffer(lines, { 1, 0 })
  local getcharstr, input = vim.fn.getcharstr, utils.input
  local keys = { key }
  vim.fn.getcharstr = function()
    return table.remove(keys, 1) or "\27"
  end
  answers = answers or {}
  utils.input = function()
    return table.remove(answers, 1)
  end
  local ok, err = pcall(beamer.select_environment)
  vim.fn.getcharstr, utils.input = getcharstr, input
  assert(ok, err)
  return buf_lines(buf)
end

describe("beamer mode (Emacs parity)", function()
  it("sets BEAMER_env and its tag", function()
    eq({
      "* Frame title                                                       :B_block:",
      ":PROPERTIES:",
      ":BEAMER_env: block",
      ":END:",
    }, select({ "* Frame title" }, "b"))
  end)

  it("puts the environment tag first", function()
    eq({
      "* Frame title                                                   :B_frame:foo:",
      ":PROPERTIES:",
      ":BEAMER_env: frame",
      ":END:",
    }, select({ "* Frame title :foo:" }, "f"))
  end)

  it("removes the environment when its key is pressed again", function()
    eq({ "* H" }, select({ "* H :B_block:", ":PROPERTIES:", ":BEAMER_env: block", ":END:" }, "b"))
  end)

  it("asks for the column width with |", function()
    eq({
      "* Col                                                                 :BMCOL:",
      ":PROPERTIES:",
      ":BEAMER_col: 0.5",
      ":END:",
    }, select({ "* Col" }, "|", { "0.5" }))
  end)

  it("asks for the frame reference and overlay of an againframe", function()
    eq({
      "* Again                                                        :B_againframe:",
      ":PROPERTIES:",
      ":BEAMER_env: againframe",
      ":BEAMER_ref: *Frame",
      ":BEAMER_act: <2>",
      ":END:",
    }, select({ "* Again" }, "A", { "*Frame", "<2>" }))
    eq({ "* Again" }, select({
      "* Again :B_againframe:",
      ":PROPERTIES:",
      ":BEAMER_env: againframe",
      ":BEAMER_ref: *F",
      ":BEAMER_act: <2>",
      ":END:",
    }, "A"))
  end)

  it("tags the entry when BEAMER_env is set as a property", function()
    local buf = org_buffer({ "* H" }, { 1, 0 })
    beamer.mode(buf, true)
    require("org.properties").set_property(nil, "BEAMER_env", "note")
    eq({
      "* H                                                                  :B_note:",
      ":PROPERTIES:",
      ":BEAMER_env: note",
      ":END:",
    }, buf_lines(buf))
    beamer.mode(buf, false)
  end)

  it("maps <C-c><C-b> while the mode is on and fires OrgBeamerMode", function()
    local buf = org_buffer({ "* H" }, { 1, 0 })
    local events = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "OrgBeamerMode",
      callback = function(ev)
        events[#events + 1] = ev.data.enabled
      end,
    })
    local before = vim.fn.maparg("<C-c><C-b>", "n", false, true)
    eq(true, beamer.mode(buf, true))
    eq("org: Select Beamer environment", vim.fn.maparg("<C-c><C-b>", "n", false, true).desc)
    eq(false, beamer.mode(buf, false))
    eq(before.desc, vim.fn.maparg("<C-c><C-b>", "n", false, true).desc)
    vim.api.nvim_del_autocmd(id)
    eq({ true, false }, events)
  end)

  it("starts with #+STARTUP: beamer or startup_with_beamer_mode", function()
    local buf = org_buffer({ "#+STARTUP: beamer", "* H" }, { 1, 0 })
    beamer.setup_buffer(buf)
    ok(beamer.enabled(buf))
    beamer.mode(buf, false)
    local buf2 = org_buffer({ "* H" }, { 1, 0 })
    beamer.setup_buffer(buf2)
    ok(not beamer.enabled(buf2))
    config.opts.startup_with_beamer_mode = true
    beamer.setup_buffer(buf2)
    config.opts.startup_with_beamer_mode = false
    ok(beamer.enabled(buf2))
    beamer.mode(buf2, false)
  end)
end)
