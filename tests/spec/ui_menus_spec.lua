local ui = require("org.ui")
local utils = require("org.utils")

local function with_stub(tbl, key, fn, body)
  local orig = tbl[key]
  tbl[key] = fn
  local ok_, err = pcall(body)
  tbl[key] = orig
  if not ok_ then
    error(err, 0)
  end
end

--- Feed `keys` to utils.getchar, one per call (nil = <Esc>).
local function with_keys(keys, body)
  with_stub(utils, "getchar", function()
    return table.remove(keys, 1)
  end, body)
end

local function hl_text(lines, hls, group)
  local out = {}
  for _, h in ipairs(hls) do
    if h[4] == group then
      out[#out + 1] = lines[h[1] + 1]:sub(h[2] + 1, h[3])
    end
  end
  return out
end

describe("ui.menu layout", function()
  it("aligns keys, labels and states in sections", function()
    local lines, hls = ui._menu_lines({
      { heading = true, label = "Options" },
      { key = "b", label = "Body only", state = "on", value = 1 },
      { key = "s", label = "Export scope", state = "buffer", value = 2 },
      { heading = true, label = "Export" },
      { key = "h", label = "HTML", items = { { key = "h", label = "file", value = 3 } } },
      { key = " ", label = "Clear", value = 4 },
    })
    eq({
      " Options",
      "  b    Body only         on",
      "  s    Export scope  buffer",
      "",
      " Export",
      "  h    HTML               ›",
      "  SPC  Clear",
    }, lines)
    eq({ "Options", "Export" }, hl_text(lines, hls, "OrgMenuHeading"))
    eq({ "b", "s", "h", "SPC" }, hl_text(lines, hls, "OrgMenuKey"))
    eq({ "on" }, hl_text(lines, hls, "OrgMenuOn"))
    eq({ "buffer" }, hl_text(lines, hls, "OrgMenuValue"))
    eq({ "›" }, hl_text(lines, hls, "OrgMenuMore"))
  end)

  it("drops the blank lines between sections when compact", function()
    local lines = ui._menu_lines({
      { heading = true, label = "A" },
      { key = "a", label = "one", value = 1 },
      { heading = true, label = "B" },
      { key = "b", label = "two", value = 2 },
    }, nil, true)
    eq({ " A", "  a  one", " B", "  b  two" }, lines)
  end)

  it("puts column 2 items right of the previous one", function()
    local lines = ui._menu_lines({
      { key = "a", label = "Alpha", value = 1 },
      { key = "b", label = "Beta", value = 2, column = 2 },
      { key = "c", label = "Gamma long", value = 3 },
    })
    eq({ "  a  Alpha         b  Beta", "  c  Gamma long" }, lines)
  end)

  it("goes back from a submenu with <BS>", function()
    local items = {
      { key = "h", label = "HTML", items = { { key = "h", label = "file", value = "html" } } },
      { key = "m", label = "Markdown", value = "md" },
    }
    local result
    with_keys({ "h", vim.keycode("<BS>"), "m" }, function()
      result = ui.menu({ title = "T", items = items })
    end)
    eq("md", result)
  end)
end)

describe("ui.choose", function()
  local items = {
    { value = "orgtbl-to-tsv", desc = "tab-separated" },
    { value = "orgtbl-to-csv", desc = "comma-separated" },
    { value = "orgtbl-to-latex" },
  }

  it("is the completing command line without a UI", function()
    local seen
    with_stub(utils, "input_complete", function(prompt, values, default)
      seen = { prompt, values, default }
      return "orgtbl-to-csv"
    end, function()
      eq("orgtbl-to-csv", ui.choose({ prompt = "Format: ", items = items, default = "orgtbl-to-tsv" }))
    end)
    eq({ "Format: ", { "orgtbl-to-tsv", "orgtbl-to-csv", "orgtbl-to-latex" }, "orgtbl-to-tsv" }, seen)
  end)

  describe("in a float", function()
    before_each(function()
      ui._force_float = true
    end)
    after_each(function()
      ui._force_float = nil
    end)

    it("starts on the default and picks with <CR>", function()
      with_keys({ "\r" }, function()
        eq("orgtbl-to-csv", ui.choose({ prompt = "Format: ", items = items, default = "orgtbl-to-csv" }))
      end)
    end)

    it("moves with j / k, wrapping around", function()
      with_keys({ "k", "\r" }, function()
        eq("orgtbl-to-latex", ui.choose({ prompt = "Format: ", items = items }))
      end)
      with_keys({ "j", "j", "j", "\r" }, function()
        eq("orgtbl-to-tsv", ui.choose({ prompt = "Format: ", items = items }))
      end)
    end)

    it("picks the row of a key", function()
      with_keys({ "3" }, function()
        eq("orgtbl-to-latex", ui.choose({ prompt = "Format: ", items = { "a", "b", "orgtbl-to-latex" } }))
      end)
    end)

    it("cancels with <Esc> and closes the float", function()
      local wins = #vim.api.nvim_list_wins()
      with_keys({ nil }, function()
        eq(nil, ui.choose({ prompt = "Format: ", items = items }))
      end)
      eq(wins, #vim.api.nvim_list_wins())
    end)

    it("is wide enough for its title and footer when the rows are short", function()
      local cfg
      with_stub(utils, "getchar", function()
        cfg = vim.api.nvim_win_get_config(0)
        return "1"
      end, function()
        eq("x", ui.choose({ prompt = "Insert export template: ", items = { "x", "y" } }))
      end)
      local function text(chunks)
        local out = {}
        for _, c in ipairs(chunks) do
          out[#out + 1] = c[1]
        end
        return table.concat(out)
      end
      local title, footer = text(cfg.title), text(cfg.footer)
      eq(" Insert export template ", title)
      ok(cfg.width >= vim.fn.strdisplaywidth(title), cfg.width)
      ok(cfg.width >= vim.fn.strdisplaywidth(footer), cfg.width)
    end)

    it("edits the value at the cursor with e", function()
      local seen
      with_stub(utils, "input_complete", function(prompt, _, default)
        seen = { prompt, default }
        return default .. " :splice t"
      end, function()
        with_keys({ "j", "e" }, function()
          eq("orgtbl-to-csv :splice t", ui.choose({ prompt = "Format: ", items = items, edit = true }))
        end)
      end)
      eq({ "Format: ", "orgtbl-to-csv" }, seen)
    end)

    it("uses the command line with ui.choice_prompt = input", function()
      local cfg = require("org.config").opts.ui
      local saved = cfg.choice_prompt
      cfg.choice_prompt = "input"
      local called = false
      with_stub(utils, "input_complete", function()
        called = true
        return "x"
      end, function()
        eq("x", ui.choose({ prompt = "Format: ", items = items }))
      end)
      cfg.choice_prompt = saved
      ok(called)
    end)
  end)
end)

describe("table export format prompt", function()
  it("offers the translators, starting on the one of the file extension", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/out.csv"
    org_buffer({ "| a | b |" }, { 1, 2 })
    local seen
    with_stub(utils, "input", function()
      return path
    end, function()
      with_stub(ui, "choose", function(opts)
        seen = opts
        return opts.default
      end, function()
        with_stub(utils, "notify", function() end, function()
          require("org.table").export()
        end)
      end)
    end)
    eq("orgtbl-to-csv", seen.default)
    eq(true, seen.edit)
    eq("orgtbl-to-tsv", seen.items[1].value)
    eq({ "a,b" }, utils.readfile(path))
    vim.fn.delete(dir, "rf")
    vim.cmd("enew!") -- leave no modified buffer for the next spec
  end)
end)
