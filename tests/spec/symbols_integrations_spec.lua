-- Document symbols outside the language server: org.api.symbols /
-- symbol_path, and the aerial.nvim backend and outline.nvim provider
-- (both stubbed: neither plugin is installed for the tests).

local api = require("org.api")
local SK = vim.lsp.protocol.SymbolKind

local LINES = {
  "#+TITLE: Notes", -- 1
  "#+NAME: intro", -- 2
  "| a |", -- 3
  "* TODO [#A] Write [[https://x.org][the report]] :work:", -- 4
  "  Text with a <<anchor>> and <<<radio>>>.", -- 5
  "** Details", -- 6
  "   #+NAME: hello", -- 7
  "   #+begin_src sh", -- 8
  "   echo <<not-a-target>>", -- 9
  "   #+end_src", -- 10
  "*** Deep", -- 11
  "    deep text", -- 12
  "* DONE Finished", -- 13
  "* Plain [1/2]", -- 14
}

local function names(list)
  return vim.tbl_map(function(s)
    return s.name
  end, list)
end

describe("org.api.symbols", function()
  after_each(function()
    require("org").setup({})
  end)

  it("returns the outline as LSP document symbols", function()
    local buf = org_buffer(LINES)
    local syms = assert(api.symbols(buf))
    eq({ "intro", "Write the report", "Finished", "Plain" }, names(syms))
    local intro, report = syms[1], syms[2]
    eq("table", intro.type)
    eq(SK.Struct, intro.kind)
    eq({ start = { line = 1, character = 8 }, ["end"] = { line = 1, character = 13 } }, intro.selectionRange)
    eq("headline", report.type)
    eq(1, report.level)
    eq(4, report.lnum)
    eq(12, report.end_lnum)
    eq("TODO [#A] :work:", report.detail)
    eq(SK.Event, report.kind)
    -- range: the whole subtree, to the end of its last line
    eq({ start = { line = 3, character = 0 }, ["end"] = { line = 11, character = #LINES[12] } }, report.range)
    -- selection: the title as written (after TODO and priority, before tags)
    local s = LINES[4]:find("Write", 1, true) - 1
    eq(s, report.selectionRange.start.character)
    eq(LINES[4]:find(" :work:", 1, true) - 1, report.selectionRange["end"].character)
    local details = report.children[1]
    eq({ "hello", "Deep" }, names(details.children))
    eq("src_block", details.children[1].type)
    eq(SK.Function, details.children[1].kind)
    eq(SK.Constant, syms[3].kind)
    eq(SK.Namespace, syms[4].kind)
    eq({}, syms[4].children)
  end)

  it("lists targets with opts.targets, not inside blocks", function()
    local buf = org_buffer(LINES)
    local syms = assert(api.symbols(buf, { targets = true, tables = false, src_blocks = false }))
    eq({ "Write the report", "Finished", "Plain" }, names(syms))
    local children = syms[1].children
    eq({ "anchor", "radio", "Details" }, names(children))
    eq("target", children[1].type)
    eq("radio_target", children[2].type)
    eq(SK.Key, children[1].kind)
    local col = LINES[5]:find("anchor", 1, true) - 1
    eq({ start = { line = 4, character = col }, ["end"] = { line = 4, character = col + 6 } }, children[1].range)
    eq({ "Deep" }, names(children[3].children))
  end)

  it("takes kinds from opts and from the lsp extension's options", function()
    local buf = org_buffer(LINES)
    local syms = assert(api.symbols(buf, { kinds = { todo = "Interface", heading = SK.Module } }))
    eq(SK.Interface, syms[2].kind)
    eq(SK.Module, syms[4].kind)
    require("org").setup({
      extensions = {
        lsp = { autostart = false, symbol_kinds = { done = "Boolean" }, document_symbols = { tables = false } },
      },
    })
    buf = org_buffer(LINES)
    syms = assert(api.symbols(buf))
    eq({ "Write the report", "Finished", "Plain" }, names(syms))
    eq(SK.Boolean, syms[2].kind)
  end)

  it("refuses a buffer that isn't org", function()
    vim.cmd("enew!")
    vim.bo.bufhidden = "wipe"
    local syms, err = api.symbols(0)
    eq(nil, syms)
    ok(err:match("not an org buffer"))
  end)

  it("gives the headline path at a line (breadcrumbs)", function()
    local buf = org_buffer(LINES, { 12, 0 })
    local path = assert(api.symbol_path())
    eq({ "Write the report", "Details", "Deep" }, names(path))
    eq({ 1, 2, 3 }, {
      path[1].level,
      path[2].level,
      path[3].level,
    })
    eq({}, path[3].children)
    eq({ "Finished" }, names(assert(api.symbol_path({ bufnr = buf, lnum = 13 }))))
    eq({}, assert(api.symbol_path({ bufnr = buf, lnum = 2 })))
    -- a window's cursor (for a 'winbar' expression)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(win, { 7, 0 })
    vim.cmd("new")
    vim.bo.bufhidden = "wipe"
    eq({ "Write the report", "Details" }, names(assert(api.symbol_path({ win = win }))))
    local none, err = api.symbol_path()
    eq(nil, none)
    ok(err:match("not an org buffer"))
    vim.cmd("close")
  end)

  it("raises the minor API version", function()
    ok(api.has("1.1"))
  end)
end)

describe("lsp document symbols", function()
  after_each(function()
    require("org").setup({})
  end)

  it("lists targets with document_symbols.targets", function()
    require("org").setup({ extensions = { lsp = { autostart = false, document_symbols = { targets = true } } } })
    local buf = org_buffer(LINES)
    local doc = assert(require("org.extensions.lsp.util").doc_from_buf(buf))
    local syms = require("org.extensions.lsp.symbols").document(doc)
    eq({ "anchor", "radio", "Details" }, names(syms[2].children))
  end)
end)

describe("aerial backend", function()
  local set, attached
  before_each(function()
    set, attached = {}, true
    package.loaded["aerial.config"] = { update_events = "TextChanged,InsertLeave", org = { update_delay = 10 } }
    package.loaded["aerial.backends"] = {
      set_symbols = function(bufnr, items, ctx)
        set[#set + 1] = { bufnr = bufnr, items = items, ctx = ctx }
      end,
      is_backend_attached = function(_, name)
        return attached and name == "org"
      end,
    }
    package.loaded["aerial.backends.org"] = nil
  end)
  after_each(function()
    package.loaded["aerial.config"] = nil
    package.loaded["aerial.backends"] = nil
    package.loaded["aerial.backends.org"] = nil
  end)

  it("is found where aerial looks for backends", function()
    eq(require("org.integrations.aerial"), require("aerial.backends.org"))
  end)

  it("supports org buffers only", function()
    local aerial = require("aerial.backends.org")
    local buf = org_buffer(LINES)
    ok(aerial.is_supported(buf))
    vim.bo[buf].filetype = "text"
    local yes, why = aerial.is_supported(buf)
    eq(false, yes)
    ok(why:match("org"))
  end)

  it("hands aerial its symbols", function()
    local aerial = require("aerial.backends.org")
    local buf = org_buffer(LINES)
    aerial.fetch_symbols_sync(buf)
    eq(1, #set)
    eq(buf, set[1].bufnr)
    eq({ backend_name = "org", lang = "org" }, set[1].ctx)
    local items = set[1].items
    eq({ "intro", "Write the report", "Finished", "Plain" }, names(items))
    local report = items[2]
    eq("Event", report.kind)
    eq(0, report.level)
    eq(4, report.lnum)
    eq(0, report.col)
    eq(12, report.end_lnum)
    eq(#LINES[12], report.end_col)
    eq(4, report.selection_range.lnum)
    eq(LINES[4]:find("Write", 1, true) - 1, report.selection_range.col)
    local details = report.children[1]
    eq(report, details.parent)
    eq(1, details.level)
    eq({ "hello", "Deep" }, names(details.children))
    eq("Function", details.children[1].kind)
    eq(nil, items[4].children)
  end)

  it("lets post_parse_symbol drop symbols", function()
    package.loaded["aerial.config"].post_parse_symbol = function(_, item)
      return item.kind ~= "Function"
    end
    local aerial = require("aerial.backends.org")
    local buf = org_buffer(LINES)
    aerial.fetch_symbols_sync(buf)
    eq({ "Deep" }, names(set[1].items[2].children[1].children))
  end)

  it("fetches again after a change, once, while attached", function()
    local aerial = require("aerial.backends.org")
    local buf = org_buffer(LINES)
    aerial.attach(buf)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "* New" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
    vim.wait(1000, function()
      return #set > 0
    end, 5)
    eq(1, #set)
    eq("New", set[1].items[#set[1].items].name)
    -- detached: no more updates
    aerial.detach(buf)
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.wait(50)
    eq(1, #set)
    -- another backend took over: no update either
    aerial.attach(buf)
    attached = false
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.wait(50)
    eq(1, #set)
    aerial.detach(buf)
  end)
end)

describe("outline.nvim provider", function()
  after_each(function()
    package.loaded["outline.providers.org"] = nil
  end)

  it("is found where outline.nvim looks for providers", function()
    local p = require("outline.providers.org")
    eq(require("org.integrations.outline"), p)
    eq("org", p.name)
    ok(#p.get_status() > 0)
  end)

  it("supports org buffers and returns their symbols", function()
    local p = require("outline.providers.org")
    local buf = org_buffer(LINES)
    ok(p.supports_buffer(buf, {}))
    ok(p.supports_buffer(0))
    local got, got_opts
    p.request_symbols(function(syms, o)
      got, got_opts = syms, o
    end, { x = 1 })
    eq({ "intro", "Write the report", "Finished", "Plain" }, names(got))
    eq({ x = 1 }, got_opts)
    ok(got[2].range and got[2].selectionRange and got[2].children)
    vim.bo[buf].filetype = "text"
    eq(false, p.supports_buffer(buf, {}))
  end)
end)
