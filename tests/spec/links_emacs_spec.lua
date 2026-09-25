local links = require("org.links")
local config = require("org.config")

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function file_buffer(dir, name, lines, cursor)
  local buf = org_buffer(lines, cursor)
  vim.api.nvim_buf_set_name(buf, dir .. "/" .. name)
  return buf
end

describe("links (Emacs commands)", function()
  before_each(function()
    links.stored = {}
    config.opts.links.use_id = "create-if-interactive"
  end)

  it("stores links to dedicated targets, named elements and text before the first heading", function()
    local dir = tmpdir()
    local buf = file_buffer(dir, "s.org", {
      "Intro line",
      "* H",
      "See <<my target>> here.",
      "#+NAME: data",
      "| a | b |",
    }, { 3, 6 })
    local l = links.link_to_location({ bufnr = buf })
    ok(l.link:match("::my target$"), l.link)
    l = links.link_to_location({ bufnr = buf, lnum = 5 })
    ok(l.link:match("::data$"), l.link)
    eq("data", l.desc)
    l = links.link_to_location({ bufnr = buf, lnum = 1 })
    ok(l.link:match("::Intro line$"), l.link)
    vim.bo[buf].modified = false
  end)

  it("stores a link to the entry of an agenda item", function()
    local dir = tmpdir()
    local path = dir .. "/ag.org"
    local today = os.date("%Y-%m-%d")
    vim.fn.writefile({ "* TODO Agenda entry", "SCHEDULED: <" .. today .. ">" }, path)
    local saved = config.opts.agenda_files
    config.opts.agenda_files = { path }
    config.opts.links.use_id = false
    require("org.agenda").open_agenda({ span = "day" })
    local view = require("org.agenda.view")
    for l, it in pairs(view.state.line_items) do
      if it.title == "Agenda entry" then
        vim.api.nvim_win_set_cursor(0, { l, 0 })
      end
    end
    local l = links.link_to_location({ interactive = true })
    view.quit(true)
    config.opts.agenda_files = saved
    ok(l and l.link:match("ag%.org::%*Agenda entry$"), vim.inspect(l))
  end)

  it("inserts the last stored link and all stored links", function()
    local buf = org_buffer({ "x", "" }, { 1, 0 })
    links.store("https://a.example", "A")
    links.store("https://b.example", "B")
    links.insert_last_stored_link()
    eq("x[[https://b.example][B]]", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    links.insert_all_links()
    eq({ "- [[https://b.example][B]]", "- [[https://a.example][A]]" }, vim.list_slice(buf_lines(buf), 2, 3))
    eq(0, #links.stored)
  end)

  it("moves to next / previous links of every kind", function()
    org_buffer({ "a https://x.org b", "none", "c <mailto:m@n.o> [[*H]]" }, { 1, 0 })
    links.next_link()
    eq({ 1, 2 }, vim.api.nvim_win_get_cursor(0))
    links.next_link()
    eq({ 3, 2 }, vim.api.nvim_win_get_cursor(0))
    links.next_link()
    eq({ 3, 17 }, vim.api.nvim_win_get_cursor(0))
    links.prev_link()
    eq({ 3, 2 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("opens the entry's link from its headline", function()
    org_buffer({ "* Entry", "Go to [[*Target]].", "* Target" }, { 1, 0 })
    links.open_at_point_or_entry()
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    eq(false, (function()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      return links.open_at_point_or_entry()
    end)())
  end)
end)

describe("ids", function()
  it("copies, stores and goes to IDs", function()
    local dir = tmpdir()
    config.opts.id.locations_file = dir .. "/ids.json"
    require("org.id")._reset()
    local buf = file_buffer(dir, "i.org", { "* A", "* B" }, { 2, 0 })
    local id = require("org.id").copy()
    ok(id)
    eq(id, vim.fn.getreg('"'))
    local stored = require("org.id").store_link()
    eq("id:" .. id, stored.link)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    ok(require("org.id").goto(id))
    eq("* B", vim.api.nvim_get_current_line())
    vim.bo[buf].modified = false
  end)
end)

describe("attachments", function()
  it("attaches buffers, symbolic links and syncs the ATTACH tag", function()
    local dir = tmpdir()
    config.opts.id.locations_file = dir .. "/ids.json"
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(other, 0, -1, false, { "hello" })
    vim.api.nvim_buf_set_name(other, dir .. "/notes.txt")
    local buf = file_buffer(dir, "a.org", { "* Task" }, { 1, 0 })
    local attach = require("org.attach")
    local dest = attach.attach_buffer(other, { bufnr = buf, lnum = 1 })
    eq({ "hello" }, vim.fn.readfile(dest))
    ok(buf_lines(buf)[1]:match(":ATTACH:"))
    vim.fn.writefile({ "src" }, dir .. "/src.txt")
    local link = attach.attach_file(dir .. "/src.txt", "lns", { bufnr = buf, lnum = 1 })
    -- lns is a symbolic link to the absolute path (org-attach-method)
    eq(dir .. "/src.txt", vim.uv.fs_readlink(link))
    eq({ "src" }, vim.fn.readfile(link))
    vim.fn.delete(vim.fn.fnamemodify(dest, ":h"), "rf")
    local orig = require("org.utils").confirm
    require("org.utils").confirm = function()
      return false
    end
    attach.sync({ bufnr = buf, lnum = 1 })
    require("org.utils").confirm = orig
    ok(not buf_lines(buf)[1]:match(":ATTACH:"), buf_lines(buf)[1])
    eq("../../src.txt", attach.relative_path("/a/src.txt", "/a/b/c"))
    vim.bo[buf].modified = false
    vim.bo[other].modified = false
  end)
end)

describe("edit special", function()
  it("edits example blocks, export blocks and fixed-width areas", function()
    local buf = org_buffer({
      "#+begin_example",
      ",* not a heading",
      "#+end_example",
      ": fixed one",
      ": fixed two",
      "#+begin_export html",
      "<b>x</b>",
      "#+end_export",
    }, { 2, 0 })
    local special = require("org.special")
    special.edit_element(buf, 2)
    eq({ "* not a heading" }, buf_lines(0))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "* changed" })
    vim.cmd("write")
    vim.cmd("bwipeout!")
    vim.api.nvim_set_current_buf(buf)
    eq(",* changed", buf_lines(buf)[2])
    special.edit_element(buf, 5)
    eq({ "fixed one", "fixed two" }, buf_lines(0))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "only", "" })
    vim.cmd("write")
    vim.cmd("bwipeout!")
    vim.api.nvim_set_current_buf(buf)
    eq({ ": only", ":" }, vim.list_slice(buf_lines(buf), 4, 5))
    special.edit_element(buf, 7)
    eq("html", vim.bo.filetype)
    vim.cmd("bwipeout!")
    vim.api.nvim_set_current_buf(buf)
    eq(false, special.edit_element(buf, 100))
  end)

  it("stores coderef links from a src edit buffer", function()
    local dir = tmpdir()
    local buf = file_buffer(dir, "c.org", { "#+begin_src sh", "echo hi (ref:greet)", "#+end_src" }, { 2, 0 })
    require("org.babel").edit_special()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local l = links.link_to_location({ interactive = false })
    ok(l and l.link:match("::%(greet%)$"), vim.inspect(l))
    vim.cmd("bwipeout!")
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].modified = false
  end)
end)
