-- Org-aware indentation ('indentexpr', TAB, org-indent-region and
-- friends) and filling ('formatexpr', gq) against Emacs Org 9.8.10.
local config = require("org.config")
vim.g.org_test = true

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local function quiet(body)
  local orig = vim.notify
  vim.notify = function() end
  local ok, err = pcall(body)
  vim.notify = orig
  if not ok then
    error(err, 0)
  end
end

local function indentation(buf)
  local out = {}
  for i, l in ipairs(buf_lines(buf)) do
    out[i] = #l:match("^%s*")
  end
  return out
end

describe("indentation (expectations from Emacs 9.8.10)", function()
  local cases = dofile(root .. "/tests/fixtures/indent_emacs_cases.lua")
  local saved
  before_each(function()
    saved = config.opts.adapt_indentation
  end)
  after_each(function()
    config.opts.adapt_indentation = saved
  end)

  for _, c in ipairs(cases) do
    local label = c.name .. " adapt=" .. tostring(c.adapt)
    it("org-indent-line on each line: " .. label, function()
      config.opts.adapt_indentation = c.adapt
      local cols = {}
      for k = 1, #c.text do
        local buf = org_buffer(c.text, { k, 0 })
        require("org.indent").indent_line(k)
        cols[k] = indentation(buf)[k]
      end
      eq(c.columns, cols)
    end)

    it("org-indent-region on the buffer: " .. label, function()
      config.opts.adapt_indentation = c.adapt
      local buf = org_buffer(c.text, { 1, 0 })
      require("org.indent").indent_region(buf, 1, #c.text)
      eq(c.region, buf_lines(buf))
    end)
  end
end)

describe("indentexpr", function()
  it("is set in org buffers and indents new lines after `o`", function()
    local buf = org_buffer({ "* H", "- item", "  text" }, { 3, 0 })
    eq("v:lua.require'org.indent'.indentexpr()", vim.bo[buf].indentexpr)
    vim.cmd("normal! ox")
    -- Emacs: RET then org-indent-line indents like the line above
    eq("  x", buf_lines(buf)[4])
  end)

  it("indents the body with adapt_indentation", function()
    config.opts.adapt_indentation = true
    local buf = org_buffer({ "** H", "text" }, { 2, 0 })
    vim.cmd("silent normal! ==")
    config.opts.adapt_indentation = false
    -- Emacs 9.8.10: org-indent-line with org-adapt-indentation t
    eq("   text", buf_lines(buf)[2])
  end)

  it("= keeps the contents of example blocks and never moves items", function()
    -- line by line (a documented difference): Emacs's org-indent-region
    -- moves the example block and the list as a whole, see indent_region
    local buf = org_buffer({ "* H", "  #+begin_example", "    x", "      y", "  #+end_example", "   - a" }, { 1, 0 })
    vim.cmd("silent normal! gg=G")
    eq({ "* H", "#+begin_example", "    x", "      y", "#+end_example", "   - a" }, buf_lines(buf))
  end)
end)

describe("indent commands", function()
  it("indent_region moves example blocks and lists as a whole", function()
    local buf = org_buffer({ "* H", "  #+begin_example", "    x", "      y", "  #+end_example", "   - a" }, { 1, 0 })
    require("org.actions").run("indent_region")
    -- Emacs 9.8.10: org-indent-region
    eq({ "* H", "#+begin_example", "  x", "    y", "#+end_example", "- a" }, buf_lines(buf))
  end)

  it("indent_block indents the block at point", function()
    local buf = org_buffer({ "* H", "   #+begin_quote", "      q", "   #+end_quote", "   after" }, { 2, 0 })
    quiet(function()
      require("org.actions").run("indent_block")
    end)
    -- Emacs 9.8.10: org-indent-block on the #+begin line
    eq({ "* H", "#+begin_quote", "q", "#+end_quote", "   after" }, buf_lines(buf))
  end)

  it("indent_block refuses outside a block (and inside a quote's paragraph)", function()
    local msg
    local orig = vim.notify
    vim.notify = function(m)
      msg = m
    end
    org_buffer({ "* H", "#+begin_quote", "q", "#+end_quote" }, { 3, 0 })
    require("org.indent").indent_block()
    vim.notify = orig
    ok(msg:match("Not at a block"))
  end)

  it("indent_drawer indents the drawer and aligns its properties", function()
    local buf = org_buffer({ "* H", "  :PROPERTIES:", "    :ID: x", ":END:" }, { 2, 0 })
    quiet(function()
      require("org.indent").indent_drawer()
    end)
    -- Emacs 9.8.10: org-indent-drawer
    eq({ "* H", ":PROPERTIES:", ":ID:       x", ":END:" }, buf_lines(buf))
  end)

  it("unindent_buffer removes the common indentation of each element", function()
    local buf = org_buffer({
      "  pre",
      "* H",
      "    para",
      "      more",
      "",
      "    - a",
      "      - b",
      "** H2",
      "   text",
    }, { 1, 0 })
    require("org.indent").unindent_buffer()
    -- Emacs 9.8.10: org-unindent-buffer
    eq({ "pre", "* H", "para", "  more", "", "- a", "  - b", "** H2", "text" }, buf_lines(buf))
  end)
end)

describe("filling (expectations from Emacs 9.8.10, fill-column 30)", function()
  local cases = dofile(root .. "/tests/fixtures/fill_emacs_cases.lua")
  local function fill(text, s, e)
    local buf = org_buffer(text, { s, 0 })
    vim.bo[buf].textwidth = 30
    -- gq on a closed fold formats the whole fold
    local foldenable = vim.wo.foldenable
    vim.wo.foldenable = false
    eq("v:lua.require'org.fill'.formatexpr()", vim.bo[buf].formatexpr)
    vim.api.nvim_win_set_cursor(0, { s, 0 })
    local ok, err = pcall(vim.cmd, s == e and "normal! gqq" or "normal! gqG")
    vim.wo.foldenable = foldenable
    if not ok then
      error(err, 0)
    end
    return buf_lines(buf)
  end
  for _, c in ipairs(cases) do
    for key, expected in pairs(c.results) do
      it(c.name .. " gq on " .. (key == "region" and "the buffer" or ("line " .. key)), function()
        if key == "region" then
          eq(expected, fill(c.text, 1, #c.text))
        else
          eq(expected, fill(c.text, key, key))
        end
      end)
    end
  end
end)
