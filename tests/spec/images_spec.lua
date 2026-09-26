-- Inline image and LaTeX previews (org-link-preview, org-latex-preview).
local images = require("org.ui.images")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
dir = vim.uv.fs_realpath(dir)

--- A PNG file of `w` x `h` pixels (only the header matters here).
local function png(name, w, h)
  local function u32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
  end
  local bytes = "\137PNG\r\n\26\n" .. u32(13) .. "IHDR" .. u32(w) .. u32(h) .. "\8\6\0\0\0"
  local path = dir .. "/" .. name
  local f = assert(io.open(path, "wb"))
  f:write(bytes)
  f:close()
  return path
end

local function file_buffer(name, lines)
  local path = dir .. "/" .. name
  vim.fn.writefile(lines, path)
  vim.cmd("silent! %bwipeout!")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

--- A fake vim.ui.img that records what would be sent to the terminal.
local function fake_img()
  local img = { calls = {}, live = {}, next = 0 }
  function img.set(data_or_id, o)
    if type(data_or_id) == "string" then
      img.next = img.next + 1
      img.live[img.next] = vim.deepcopy(o)
      table.insert(img.calls, { "new", img.next, vim.deepcopy(o) })
      return img.next
    end
    img.live[data_or_id] = vim.deepcopy(o)
    table.insert(img.calls, { "move", data_or_id, vim.deepcopy(o) })
    return data_or_id
  end
  function img.del(id)
    img.live[id] = nil
    table.insert(img.calls, { "del", id })
    return true
  end
  return img
end

local native = {
  name = "native",
  needs_png = true,
  show = function(bufnr, p, row, col)
    local lines = {}
    for _ = 1, p.height do
      lines[#lines + 1] = { { "", "Normal" } }
    end
    p.lines = vim.api.nvim_buf_set_extmark(bufnr, vim.api.nvim_create_namespace("org.images"), row, col, {
      virt_lines = lines,
      right_gravity = false,
    })
  end,
  hide = function(bufnr, p)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, vim.api.nvim_create_namespace("org.images"), p.lines)
  end,
}

describe("image previews", function()
  local img
  before_each(function()
    img = fake_img()
    images._img = img
    images._backend = native
    png("cat.png", 400, 200)
    png("dog.png", 100, 100)
  end)
  after_each(function()
    images.clear(0)
    images.sync()
    images._img = nil
    images._backend = nil
  end)

  it("reads the size of a PNG", function()
    eq({ 400, 200 }, { images.png_size(dir .. "/cat.png") })
    eq({}, { images.png_size(dir .. "/missing.png") })
  end)

  it("fits an image into the cells it may use, keeping its shape", function()
    -- 10x20 pixel cells: 400x200 px is 40 columns by 10 rows
    eq({ 40, 10 }, { images.fit(400, 200) })
    eq({ 20, 5 }, { images.fit(400, 200, 20) })
    eq({ 16, 4 }, { images.fit(400, 200, nil, 4) })
  end)

  it("finds image links without a description", function()
    local buf = file_buffer("links.org", {
      "* Pictures",
      "[[file:cat.png]]",
      "[[./dog.png][a dog]]",
      "file:dog.png and [[file:missing.png]] and [[file:notes.txt]]",
      "#+begin_src org",
      "[[file:cat.png]]",
      "#+end_src",
    })
    local found = images.find_image_links(buf, 1, 7)
    eq(2, #found)
    eq({ 2, 0, dir .. "/cat.png" }, { found[1].row, found[1].col, found[1].path })
    eq({ 4, 0, dir .. "/dog.png" }, { found[2].row, found[2].col, found[2].path })
    -- with a count of 1, links with a description too
    eq(3, #images.find_image_links(buf, 1, 7, true))
  end)

  it("sizes images like org-image-actual-width", function()
    local cfg = require("org.config").opts.ui.images
    local saved = cfg.actual_width
    local buf = file_buffer("attr.org", { "#+ATTR_HTML: :width 900", "#+ATTR_ORG: :width 200", "[[file:cat.png]]" })
    -- t (the default): the image's own size, #+ATTR ignored
    eq(nil, images.find_image_links(buf, 1, 3)[1].width)
    cfg.actual_width = false
    eq({ px = 200 }, images.find_image_links(buf, 1, 3)[1].width)
    cfg.actual_width = 300
    eq({ px = 300 }, images.find_image_links(buf, 1, 3)[1].width)
    cfg.actual_width = { 150 }
    local w = function(attrs)
      return images.image_width(buf, 3, attrs)
    end
    eq({ px = 150 }, w({}))
    eq({ fraction = 0.5 }, w({ "#+ATTR_ORG: :width 50%" }))
    eq({ fraction = 0.7 }, w({ "#+ATTR_LATEX: :width 0.7\\linewidth" }))
    eq({ px = 300 }, w({ "#+ATTR_ORG: :width 300px" }))
    eq(nil, w({ "#+ATTR_ORG: :width t" }))
    -- unreadable ATTR_ORG: another ATTR_x, else the default
    eq({ px = 900 }, w({ "#+ATTR_ORG: :width 4in", "#+ATTR_HTML: :width 900" }))
    eq({ px = 150 }, w({ "#+ATTR_ORG: :width 4in" }))
    cfg.actual_width = saved
  end)

  it("previews an image link used as a description", function()
    local buf = file_buffer("desc.org", { "[[https://example.com][file:cat.png]]", "[[file:doc.pdf][<file:dog.png>]]" })
    local found = images.find_image_links(buf, 1, 2)
    eq({ dir .. "/cat.png", dir .. "/dog.png" }, { found[1].path, found[2].path })
    -- with include_linked, the link's own target is used
    eq(0, #images.find_image_links(buf, 1, 2, true))
  end)

  it("aligns stand-alone images like org-image-align", function()
    local lines = {
      "#+ATTR_ORG: :align center",
      "[[file:cat.png]]",
      "",
      "text [[file:cat.png]]",
      "#+ATTR_HTML: :center t",
      "[[file:cat.png]]",
    }
    local buf = file_buffer("align.org", lines)
    local found = images.find_image_links(buf, 1, 6)
    eq({ "center", nil, "center" }, { found[1].align, found[2].align, found[3].align })
  end)

  it("finds LaTeX fragments and environments", function()
    local buf = file_buffer("math.org", {
      "Euler: $e^{i\\pi}+1=0$ and \\(a^2\\), not $5 or $10.",
      "\\[ \\int_0^1 x\\,dx \\]",
      "\\begin{align}",
      "a &= b",
      "\\end{align}",
    })
    local f = images.find_latex_fragments(buf, 1, 5)
    eq(
      { "$e^{i\\pi}+1=0$", "\\(a^2\\)", "\\[ \\int_0^1 x\\,dx \\]", "\\begin{align}\na &= b\n\\end{align}" },
      vim.tbl_map(function(x)
        return x.text
      end, f)
    )
    eq({ 3, 5 }, { f[4].row, f[4].end_row })
  end)

  it("reserves rows under the link and places the image there", function()
    local buf = file_buffer("show.org", { "* Pictures", "[[file:cat.png]]", "after" })
    eq(1, images.show_links(buf, 1, 3))
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    local reserved = 0
    for _, m in ipairs(marks) do
      reserved = reserved + #(m[4].virt_lines or {})
    end
    eq(10, reserved)
    images.sync()
    eq(1, #img.calls)
    local call = img.calls[1]
    eq("new", call[1])
    -- the row after the link's screen row, at the link's column
    eq(vim.fn.screenpos(0, 2, 1).row + 1, call[3].row)
    eq(vim.fn.screenpos(0, 2, 1).col, call[3].col)
    eq({ 40, 10 }, { call[3].width, call[3].height })
    -- nothing moved: nothing is sent again
    images.sync()
    eq(1, #img.calls)
  end)

  it("hides images of folded lines and removes them with their link", function()
    local buf = file_buffer("fold.org", { "* Pictures", "[[file:dog.png]]", "* Next" })
    images.show_links(buf, 1, 3)
    images.sync()
    eq(1, vim.tbl_count(img.live))
    vim.cmd("normal! zx")
    vim.cmd("1foldclose")
    images.sync()
    eq(0, vim.tbl_count(img.live))
    vim.cmd("1foldopen")
    images.sync()
    eq(1, vim.tbl_count(img.live))
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "no link any more" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    images.sync()
    eq(0, vim.tbl_count(img.live))
  end)

  it("link_preview toggles the entry, 16 shows the buffer and 64 hides it", function()
    local buf = file_buffer("toggle.org", { "* A", "[[file:cat.png]]", "* B", "[[file:dog.png]]" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    images.link_preview()
    images.sync()
    eq(1, vim.tbl_count(img.live))
    -- again on the entry: displayed again, not hidden (like Emacs)
    images.link_preview()
    images.sync()
    eq(1, vim.tbl_count(img.live))
    -- on the link: toggled off
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    images.link_preview()
    images.sync()
    eq(0, vim.tbl_count(img.live))
    -- 4 hides the entry
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    images.link_preview()
    images.link_preview(4)
    images.sync()
    eq(0, vim.tbl_count(img.live))
    images.link_preview(16)
    images.sync()
    eq(2, vim.tbl_count(img.live))
    images.link_preview(64)
    images.sync()
    eq(0, vim.tbl_count(img.live))
    eq(0, #vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("org.images"), 0, -1, {}))
  end)

  it("#+STARTUP: linkpreviews previews the file when it opens", function()
    local path = dir .. "/startup.org"
    vim.fn.writefile({ "#+STARTUP: linkpreviews", "* A", "[[file:dog.png]]" }, path)
    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.wait(200, function()
      return #vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("org.images"), 0, -1, {}) > 0
    end)
    images.sync()
    eq(1, vim.tbl_count(img.live))
  end)

  it("stacks two images of the same line", function()
    local buf = file_buffer("two.org", { "[[file:dog.png]] [[file:cat.png]]", "" })
    images.show_links(buf, 1, 2)
    images.sync()
    local rows = {}
    for _, o in pairs(img.live) do
      rows[#rows + 1] = o.row
    end
    table.sort(rows)
    local first = vim.fn.screenpos(0, 1, 1).row + 1
    -- dog.png is 10x5 cells, then cat.png under it
    eq({ first, first + 5 }, rows)
  end)
end)

describe("latex fragments", function()
  local function texts(buf, a, b)
    return vim.tbl_map(function(x)
      return x.text
    end, images.find_latex_fragments(buf, a or 1, b or math.huge))
  end

  it("follows the org-element rules for dollars", function()
    local buf = file_buffer("dollars.org", {
      "a$x$ yes, $y$. yes, $ no$, $no $, $z$_no, $$w$$ yes, \\$5 and $6",
    })
    eq({ "$x$", "$y$", "$$w$$" }, texts(buf))
  end)

  it("spans lines of a paragraph, not blank lines", function()
    local buf = file_buffer("multi.org", { "Here \\[ a +", "b \\] and $x", "and y$.", "", "\\(c", "", "d\\)" })
    local f = images.find_latex_fragments(buf, 1, math.huge)
    eq({ "\\[ a +\nb \\]", "$x\nand y$" }, texts(buf))
    eq({ 1, 2, 2, 3 }, { f[1].row, f[1].end_row, f[2].row, f[2].end_row })
  end)

  it("skips verbatim, code, link targets, blocks and fixed-width lines", function()
    local buf = file_buffer("skip.org", {
      "=$a$= ~$b$~ [[file:$c$.png][$d$]]",
      ": $e$",
      "#+begin_src tex",
      "$f$",
      "#+end_src",
      "#+begin_note",
      "$g$",
      "#+end_note",
      "#+OPTIONS: $h$",
      "#+TITLE: $i$",
    })
    eq({ "$d$", "$g$", "$i$" }, texts(buf))
  end)

  it("finds environments ended on their own line", function()
    local buf = file_buffer("env.org", {
      "\\begin{eq2}",
      "x",
      "\\END{eq2}  ",
      "\\begin{align} a \\end{align}",
      "\\begin{split}",
      "* next",
      "\\end{split}",
    })
    local f = images.find_latex_fragments(buf, 1, math.huge)
    eq(1, #f)
    eq({ 1, 3 }, { f[1].row, f[1].end_row })
  end)
end)

describe("latex preview command", function()
  local img, renders, saved_render
  before_each(function()
    img = fake_img()
    images._img = img
    images._backend = native
    renders = {}
    saved_render = images.render_latex
    -- renders finish when the test says so
    images.render_latex = function(text, _, cb)
      renders[#renders + 1] = { text = text, cb = cb }
    end
    png("f.png", 60, 20)
  end)
  after_each(function()
    images.render_latex = saved_render
    images.clear(0)
    images.sync()
    images._img = nil
    images._backend = nil
  end)
  local function finish_all()
    for _, r in ipairs(renders) do
      r.cb(dir .. "/f.png")
    end
    renders = {}
  end
  local function count()
    return #vim.tbl_filter(function(m)
      return m[4].virt_lines ~= nil
    end, vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("org.images"), 0, -1, { details = true }))
  end

  it("toggles the fragment at point only", function()
    file_buffer("toggle_ltx.org", { "* A", "$a$ and $b$" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    images.latex_preview()
    eq(1, #renders)
    finish_all()
    eq(1, count())
    images.latex_preview()
    eq(0, count())
    -- on the entry: both, and again: displayed again
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    images.latex_preview()
    finish_all()
    eq(2, count())
    images.latex_preview()
    finish_all()
    eq(2, count())
    images.latex_preview(4)
    eq(0, count())
  end)

  it("drops renders that finish after their preview was cleared or changed", function()
    local buf = file_buffer("stale.org", { "* A", "$a$ and $b$" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    images.latex_preview()
    images.latex_preview(64)
    finish_all()
    eq(0, count())
    images.latex_preview()
    vim.api.nvim_buf_set_text(buf, 1, 1, 1, 2, { "z" })
    finish_all()
    -- $a$ became $z$: only $b$ is shown
    eq(1, count())
  end)
end)

describe("preview upkeep", function()
  local img
  before_each(function()
    img = fake_img()
    images._img = img
    images._backend = native
    png("cat.png", 400, 200)
  end)
  after_each(function()
    images.clear(0)
    images.sync()
    images._img = nil
    images._backend = nil
  end)

  it("removes a preview when its link is edited", function()
    local buf = file_buffer("edit.org", { "[[file:cat.png]]" })
    images.show_links(buf, 1, 1)
    vim.api.nvim_buf_set_text(buf, 0, 7, 0, 7, { "x" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    images.sync()
    eq(0, vim.tbl_count(img.live))
  end)

  it("keeps the reserved rows with the link when its line is split", function()
    local buf = file_buffer("split.org", { "see [[file:cat.png]]", "next" })
    images.show_links(buf, 1, 2)
    vim.api.nvim_buf_set_text(buf, 0, 4, 0, 4, { "", "" })
    local ns = vim.api.nvim_create_namespace("org.images")
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].virt_lines then
        eq(1, m[2])
      end
    end
  end)

  it("#+STARTUP: the last word of a pair wins", function()
    local path = dir .. "/order.org"
    vim.fn.writefile({ "#+STARTUP: linkpreviews nolinkpreviews", "[[file:cat.png]]" }, path)
    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.wait(100)
    images.sync()
    eq(0, vim.tbl_count(img.live))
  end)

  it("TAB shows and folding hides previews with cycle_display", function()
    local cfg = require("org.config").opts.ui.images
    cfg.cycle_display = true
    local buf = file_buffer("cycle.org", { "* A", "[[file:cat.png]]", "** B", "[[file:cat.png]]" })
    images.cycle_display("children", 1, 4, 3)
    images.sync()
    eq(1, vim.tbl_count(img.live))
    images.cycle_display("subtree", 1, 4, 3)
    images.cycle_display("folded", 1, 4, 3)
    images.sync()
    eq(0, vim.tbl_count(img.live))
    cfg.cycle_display = false
    eq(0, #vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("org.images"), 0, -1, {}))
  end)

  it(":Org commands take a range", function()
    png("small.png", 100, 40)
    local buf = file_buffer("range.org", { "[[file:small.png]]", "", "[[file:small.png]]" })
    vim.cmd("3Org link_preview_region")
    images.sync()
    eq(1, vim.tbl_count(img.live))
    vim.cmd("Org link_preview_region")
    images.sync()
    eq(2, vim.tbl_count(img.live))
    vim.cmd("1Org remove_inline_images")
    images.sync()
    eq(1, vim.tbl_count(img.live))
    vim.cmd("Org link_preview_clear")
    images.sync()
    eq(0, vim.tbl_count(img.live))
    eq(buf, vim.api.nvim_get_current_buf())
  end)
end)

describe("image backends", function()
  after_each(function()
    images.clear(0)
    images._backend = nil
  end)
  it("start the image at the link, not after it", function()
    png("pos.png", 100, 40)
    local calls = {}
    images._backend = {
      name = "snacks",
      show = function(_, _, row, col, x)
        calls[#calls + 1] = { row, col, x }
      end,
      hide = function() end,
    }
    local buf = file_buffer("pos.org", { "* A", "  see [[file:pos.png]]", "  $a +", "  b$" })
    images.show_links(buf, 1, 4)
    -- the rows go under the end of the link, the image starts at its column
    eq({ { 1, 22, 6 } }, calls)
    calls = {}
    local saved = images.render_latex
    images.render_latex = function(_, _, cb)
      cb(dir .. "/pos.png")
    end
    images.show_latex(buf, 1, 4)
    images.render_latex = saved
    -- a fragment over two lines: under its last line, at the line's indent
    eq({ { 3, 4, 2 } }, calls)
  end)
end)

describe("image backend", function()
  it("explains why there is none", function()
    local saved = vim.deepcopy(require("org.config").opts.ui.images)
    require("org.config").opts.ui.images.backend = false
    local b, why = images.backend()
    eq(nil, b)
    ok(why:find("disabled"), why)
    require("org.config").opts.ui.images.backend = "native"
    b, why = images.backend()
    -- headless: no terminal to draw in
    eq(nil, b)
    ok(why:find("native"), why)
    require("org.config").opts.ui.images = saved
  end)

  it("picks a LaTeX process from the installed programs", function()
    local saved = require("org.config").opts.ui.latex_preview.process
    require("org.config").opts.ui.latex_preview.process = "nonexistent"
    local p, err = images.latex_process()
    eq(nil, p)
    ok(err:find("nonexistent"), err)
    require("org.config").opts.ui.latex_preview.process = saved
  end)
end)
