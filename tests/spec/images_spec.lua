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
  show = function(bufnr, p, row)
    local lines = {}
    for _ = 1, p.height do
      lines[#lines + 1] = { { "", "Normal" } }
    end
    p.lines = vim.api.nvim_buf_set_extmark(bufnr, vim.api.nvim_create_namespace("org.images"), row, 0, {
      virt_lines = lines,
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

  it("reads #+ATTR_ORG: :width", function()
    local buf = file_buffer("attr.org", { "#+ATTR_HTML: :width 900", "#+ATTR_ORG: :width 200", "[[file:cat.png]]" })
    eq(200, images.find_image_links(buf, 1, 3)[1].width)
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
    images.link_preview()
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
