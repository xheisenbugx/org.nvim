-- Fuzz: editing commands at random places of random Org text raise no Lua
-- error, and undo gives the original text back. A few fixed seeds by
-- default; see tests/helpers/fuzz.lua for ORG_FUZZ_ITERATIONS /
-- ORG_FUZZ_SEED.
local fuzz = require("tests.helpers.fuzz")
local actions = require("org.actions")
local utils = require("org.utils")

local SEEDS = fuzz.seeds(12)

-- what each command runs: an action name, or a function
local OPS = {
  "promote_heading",
  "demote_heading",
  "promote_subtree",
  "demote_subtree",
  "meta_left",
  "meta_right",
  "meta_up",
  "meta_down",
  "shift_meta_left",
  "shift_meta_right",
  "shift_meta_up",
  "shift_meta_down",
  "move_subtree_up",
  "move_subtree_down",
  "todo_next",
  "todo_prev",
  "shift_left",
  "shift_right",
  "toggle_checkbox",
  "meta_return",
  "insert_heading",
  table_align = function()
    return require("org.table").align()
  end,
}
local NAMES = {}
for k, v in pairs(OPS) do
  NAMES[#NAMES + 1] = type(k) == "number" and v or k
end
table.sort(NAMES)

local function fn_of(name)
  for k, v in pairs(OPS) do
    if k == name then
      return v
    end
  end
  return (actions.get(name))
end

describe("fuzz editing commands", function()
  local errors
  before_each(function()
    errors = {}
    vim.notify = function(msg, level)
      -- a Lua error caught by utils.run comes with its traceback; a
      -- user error ("Cannot promote to level 0") is just a message
      if level == vim.log.levels.ERROR and tostring(msg):match("stack traceback") then
        errors[#errors + 1] = msg
      end
    end
    -- nothing may prompt: every question is answered with "cancel"
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    vim.ui.select = function(_, _, cb)
      cb(nil)
    end
    vim.fn.input = function()
      return ""
    end
    vim.fn.confirm = function()
      return 0
    end
    vim.fn.getchar = function()
      return 27
    end
  end)

  --- Run 15 random commands on the text of `seed`. Returns an error
  --- message, or nil.
  local function run_seed(seed)
    local rng = fuzz.rng(seed)
    local lines = fuzz.doc(rng, { crlf = false })
    if #lines == 0 then
      lines = { "" }
    end
    local buf = org_buffer(lines, { 1, 0 })
    vim.bo[buf].undolevels = 1000
    local hist = {}
    for _ = 1, 15 do
      local before = buf_lines(buf)
      local lnum = rng:int(#before)
      local col = rng:int(0, math.max(0, #before[lnum] - 1))
      local name = rng:pick(NAMES)
      hist[#hist + 1] = ("%s@%d:%d"):format(name, lnum, col)
      local function fail(msg, extra)
        return ("seed %d: %s %s\nsteps: %s\ninput = %s%s"):format(
          seed,
          name,
          msg,
          table.concat(hist, " "),
          fuzz.dump(before),
          extra or ""
        )
      end
      vim.api.nvim_win_set_cursor(0, { lnum, col })
      -- an undo step of its own
      vim.bo[buf].undolevels = vim.bo[buf].undolevels
      local seq = vim.fn.undotree(buf).seq_cur
      errors = {}
      local finished = utils.run(fn_of(name))
      if not finished then
        vim.wait(20)
      end
      if vim.api.nvim_get_current_buf() ~= buf then
        vim.cmd("silent! only!")
        vim.api.nvim_set_current_buf(buf)
      end
      vim.cmd("stopinsert")
      if #errors > 0 then
        return fail("raised", "\n" .. errors[1])
      end
      local after = buf_lines(buf)
      vim.bo[buf].undolevels = vim.bo[buf].undolevels
      local seq_after = vim.fn.undotree(buf).seq_cur
      if not vim.deep_equal(after, before) then
        -- undo is per command: back to `before`
        vim.cmd("silent undo " .. seq)
        local undone = buf_lines(buf)
        if not vim.deep_equal(undone, before) then
          return fail("is not undone", "\ngot = " .. fuzz.dump(undone))
        end
        -- and on from the edited text, as a user would
        vim.cmd("silent undo " .. seq_after)
        if not vim.deep_equal(after, buf_lines(buf)) then
          return fail("is not redone")
        end
      end
    end
  end

  it("raise no error and undo restores the text", function()
    local failures = {}
    for _, seed in ipairs(SEEDS) do
      local msg = run_seed(seed)
      if msg then
        failures[#failures + 1] = msg
      end
    end
    if #failures > 0 then
      error(("%d of %d seeds failed\n%s"):format(#failures, #SEEDS, table.concat(failures, "\n\n")))
    end
  end)
end)
