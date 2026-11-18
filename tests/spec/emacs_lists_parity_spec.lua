-- Plain-list editing compared with Emacs Org 9.8.12 (tests/fixtures/emacs/
-- lists, scripts/emacs-parity/lists.el): each case opens a file, runs the
-- keys of cases.txt through the actions they are bound to (as a user
-- typing them) and compares the buffer and the cursor line.

local P = require("tests.emacs_parity")
local actions = require("org.actions")

local dir = P.dir .. "/lists"

-- Cases that still differ from Emacs, with the reason. A case listed here
-- must keep failing (remove it once it matches).
local KNOWN = {
  ["sort-cursor"] = "C-c ^ on a list: org-sort-list narrows to the list and sorts from point-min (no"
    .. " save-excursion), leaving point on the first item; org.nvim keeps the cursor on its line",
}

-- The keys of cases.txt and the actions their default keys run
-- (lua/org/config/mappings.lua); lists.el has the Emacs commands.
local ACTIONS = {
  ["M-RET"] = "meta_return",
  ["M-S-RET"] = "meta_shift_return",
  ["M-left"] = "meta_left",
  ["M-right"] = "meta_right",
  ["M-S-left"] = "shift_meta_left",
  ["M-S-right"] = "shift_meta_right",
  ["M-up"] = "meta_up",
  ["M-down"] = "meta_down",
  ["S-left"] = "shift_left",
  ["S-right"] = "shift_right",
  ["S-up"] = "shift_up",
  ["S-down"] = "shift_down",
  ["C-c-"] = "ctrl_c_minus",
  ["C-c*"] = "ctrl_c_star",
  ["C-cC-c"] = "context_action",
}

-- Emacs's M-RET acts at point: typed in Insert mode, where the cursor is
-- between two characters as point is (in Normal mode it acts after the
-- line).
local INSERT = { ["M-RET"] = true, ["M-S-RET"] = true }

local function line(l)
  return vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1]
end

--- Run `fn` from a mapping, as a typed key does: `keys` before it (a
--- count, or the key entering Insert mode), `after` once it is done.
local function from_mapping(keys, fn, after)
  _G.__org_lists_parity = fn
  vim.keymap.set({ "n", "i" }, "<F13>", "<Cmd>lua __org_lists_parity()<CR>")
  vim.api.nvim_feedkeys(vim.keycode(keys .. "<F13>" .. (after or "")), "x", false)
  vim.keymap.del({ "n", "i" }, "<F13>")
  _G.__org_lists_parity = nil
end

--- The output of a case: the buffer after `cmds`, run from `start`
--- ("<line>:<col>"), and "@ <line>" (the cursor's line), as lists.el.
local function run(file, start, cmds)
  vim.cmd("silent! only!")
  vim.cmd("silent! %bwipeout!")
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. file))
  vim.cmd("silent! normal! zR")
  local l0, c0 = start:match("^(%d+):(%d+)$")
  -- Emacs's point: the cursor in Insert mode, on the character after it
  -- in Normal mode
  local point = { tonumber(l0), tonumber(c0) }
  local out = {}
  local count
  local ui = require("org.ui")
  local saved = {
    menu = ui.menu,
    notify = vim.notify,
    echo = vim.api.nvim_echo,
    input = vim.fn.input,
    uinput = vim.ui.input,
    select = vim.ui.select,
    confirm = vim.fn.confirm,
    getchar = vim.fn.getchar,
    getcharstr = vim.fn.getcharstr,
  }
  local function prompted()
    error("prompted", 0)
  end
  vim.fn.input, vim.ui.input, vim.ui.select, vim.fn.confirm = prompted, prompted, prompted, prompted
  vim.fn.getchar, vim.fn.getcharstr = prompted, prompted
  -- warnings of commands that decline would clutter the output
  vim.notify = function() end
  vim.api.nvim_echo = function() end
  local okc, err = pcall(function()
    for _, c in ipairs(cmds) do
      local goto_l, goto_c = c:match("^L(%d+):(%d+)$")
      if c == "C-u" then
        count = 4
      elseif c:sub(1, 4) == "ins:" then
        local text = c:sub(5)
        vim.api.nvim_buf_set_text(0, point[1] - 1, point[2], point[1] - 1, point[2], { text })
        point[2] = point[2] + #text
      elseif goto_l then
        point = { tonumber(goto_l), tonumber(goto_c) }
      else
        local name = ACTIONS[c]
        local answer = c:match("^C%-c%^(.)$")
        if answer then
          name = "ctrl_c_caret"
          -- the sorting type, typed at the menu
          ui.menu = function(opts)
            for _, it in ipairs(opts.items) do
              if it.key == answer then
                return it.value
              end
            end
          end
        end
        assert(name, "unknown command " .. c)
        local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = line(point[1])
        local okr, e = true, nil
        local function act()
          okr, e = pcall(actions.run, name)
          local cur = vim.api.nvim_win_get_cursor(0)
          point = { cur[1], cur[2] }
        end
        if INSERT[c] then
          if point[2] >= #text and #text > 0 then
            vim.api.nvim_win_set_cursor(0, { point[1], #text - 1 })
            from_mapping("a", act, "<Esc>")
          else
            vim.api.nvim_win_set_cursor(0, point)
            from_mapping("i", act, "<Esc>")
          end
        else
          vim.api.nvim_win_set_cursor(0, { point[1], math.max(0, math.min(point[2], #text - 1)) })
          from_mapping(count and tostring(count) or "", act)
        end
        ui.menu = saved.menu
        count = nil
        -- as in Emacs: an error that left the buffer alone is a command
        -- that declined
        if not okr and not vim.deep_equal(before, vim.api.nvim_buf_get_lines(0, 0, -1, false)) then
          out[#out + 1] = "!error " .. tostring(e):gsub("\n", " ")
        end
      end
    end
  end)
  ui.menu, vim.notify, vim.api.nvim_echo = saved.menu, saved.notify, saved.echo
  vim.fn.input, vim.ui.input, vim.ui.select, vim.fn.confirm = saved.input, saved.uinput, saved.select, saved.confirm
  vim.fn.getchar, vim.fn.getcharstr = saved.getchar, saved.getcharstr
  assert(okc, err)
  vim.list_extend(out, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  out[#out + 1] = "@ " .. point[1]
  vim.bo.modified = false
  vim.cmd("silent! %bwipeout!")
  return out
end

describe("plain-list editing matches Emacs", function()
  P.freeze_time()
  local expected = P.sections(dir .. "/expected.txt")
  for _, case in ipairs(P.cases(dir .. "/cases.txt")) do
    local name, file, start = case[1], case[2], case[3]
    local cmds = vim.list_slice(case, 4)
    it(name, function()
      ok(expected[name], "no Emacs output for " .. name .. " (run make parity-fixtures)")
      local e, o = P.normalise("lists", expected[name].lines, run(file, start, cmds))
      P.compare(e, o, KNOWN[name])
    end)
  end
end)
