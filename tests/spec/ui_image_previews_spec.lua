-- Native image previews on the screen: wrapped lines, folds, window sizes,
-- and which lines may hold a previewed link.
local images = require("org.ui.images")
local ns = vim.api.nvim_create_namespace("org.images")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
dir = require("org.utils").realpath(dir)

--- A PNG file of `w` x `h` pixels (only the header matters here).
local function png(name, w, h)
  local function u32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
  end
  local f = assert(io.open(dir .. "/" .. name, "wb"))
  f:write("\137PNG\r\n\26\n" .. u32(13) .. "IHDR" .. u32(w) .. u32(h) .. "\8\6\0\0\0")
  f:close()
end

local function file_buffer(name, lines)
  local path = dir .. "/" .. name
  vim.fn.writefile(lines, path)
  vim.cmd("silent! %bwipeout!")
  vim.cmd("silent! only")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

--- A fake vim.ui.img: the images the terminal would show.
local function fake_img()
  local img = { live = {}, next = 0 }
  function img.set(d, o)
    if type(d) == "string" then
      img.next = img.next + 1
      img.live[img.next] = vim.deepcopy(o)
      return img.next
    end
    img.live[d] = vim.deepcopy(o)
    return d
  end
  function img.del(id)
    img.live[id] = nil
    return true
  end
  return img
end

local function rows_of(found)
  return vim.tbl_map(function(f)
    return f.row
  end, found)
end

describe("image previews on the screen", function()
  local img, columns, lines
  before_each(function()
    columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 80, 40
    img = fake_img()
    images._img = img
    images._backend = images._backends.native
    png("cat.png", 400, 200) -- 40x10 cells of 10x20 px
    png("dog.png", 100, 100) -- 10x5
    png("dot.png", 10, 20) -- 1x1
  end)
  after_each(function()
    images.clear(0)
    images.sync()
    images._img = nil
    images._backend = nil
    vim.cmd("silent! only")
    vim.o.columns, vim.o.lines = columns, lines
  end)

  local function live()
    local out = vim.tbl_values(img.live)
    table.sort(out, function(a, b)
      return a.row < b.row or (a.row == b.row and a.col < b.col)
    end)
    return out
  end

  local function pads(buf)
    local n = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].conceal then
        n = n + 1
      end
    end
    return n
  end

  it("sizes an image on a wrapped screen row by the columns left on that row", function()
    -- 90 columns of text before the link: it starts at column 11 of the
    -- line's second screen row, which has room for the whole image
    local buf = file_buffer("wrap.org", { "* H", string.rep("word ", 18) .. "[[file:dog.png]] tail", "next" })
    vim.wo.wrap = true
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    images.show_links(buf, 1, 3)
    images.sync()
    local o = live()[1]
    ok(o, "an image is placed")
    eq({ 10, 5 }, { o.width, o.height })
  end)

  it("puts an image under its line when the line wraps after it", function()
    -- in place, the image would cover the line's wrapped text: Emacs makes
    -- the screen line as tall as the image, here it goes below the line
    local buf = file_buffer("wrap2.org", { "* H", "[[file:dog.png]] " .. string.rep("text ", 30), "after" })
    vim.wo.wrap = true
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    images.show_links(buf, 1, 3)
    images.sync()
    local o = live()[1]
    ok(o, "an image is placed")
    vim.cmd("redraw!")
    local first = vim.fn.screenpos(0, 2, 1).row
    local h = vim.api.nvim_win_text_height(0, { start_row = 1, end_row = 1 })
    ok(o.row >= first + h.all - h.fill, "image starts after the line's text, at row " .. o.row)
    eq(0, pads(buf)) -- the link text stays readable
  end)

  it("keeps an image in place when the line fits on its screen row", function()
    local buf = file_buffer("nowrap.org", { "* H", "[[file:dog.png]] short", "after" })
    vim.wo.wrap = true
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    images.show_links(buf, 1, 3)
    images.sync()
    eq(1, pads(buf))
    vim.cmd("redraw!")
    eq(vim.fn.screenpos(0, 2, 1).row, live()[1].row)
  end)

  it("resizes an image when its window is narrowed", function()
    local buf = file_buffer("narrow.org", { "* H", "[[file:cat.png]]", "after" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    images.show_links(buf, 1, 3)
    images.sync()
    eq(40, live()[1].width)
    local win = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vnew")
    vim.api.nvim_set_current_win(win)
    vim.cmd("vertical resize 25")
    vim.cmd("doautocmd WinResized")
    vim.wait(50)
    images.sync()
    local i = vim.fn.getwininfo(win)[1]
    local o = live()[1]
    ok(o, "an image is placed")
    ok(o.col + o.width - 1 <= i.wincol + i.width - 1, "image fits its window")
  end)

  it("doesn't draw an image over the next window in a narrower window on the buffer", function()
    local buf = file_buffer("two.org", { "* H", "[[file:cat.png]]", "after" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("rightbelow vsplit")
    local narrow = vim.api.nvim_get_current_win()
    vim.cmd("vertical resize 20")
    vim.cmd("wincmd p")
    images.show_links(buf, 1, 3)
    images.sync()
    for _, w in ipairs({ vim.api.nvim_get_current_win(), narrow }) do
      local i = vim.fn.getwininfo(w)[1]
      for _, o in ipairs(live()) do
        if o.col >= i.wincol and o.col <= i.wincol + i.width - 1 then
          ok(o.col + o.width - 1 <= i.wincol + i.width - 1, "image fits window " .. w)
        end
      end
    end
  end)

  it("shows the link text of an image on the first line of a closed fold", function()
    local buf = file_buffer("fold.org", { "* See [[file:dog.png]] here", "body", "* Next", "text" })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    images.show_links(buf, 1, 4)
    images.sync()
    eq(1, #live())
    eq(1, pads(buf))
    vim.cmd("1foldclose")
    images.sync()
    eq(-1 ~= vim.fn.foldclosed(1), true)
    eq(0, #live())
    eq(0, pads(buf)) -- no blank columns in place of the link
    vim.cmd("1foldopen")
    images.sync()
    eq(1, #live())
    eq(1, pads(buf))
  end)

  it("keeps an image as tall as the line on the first line of a closed fold", function()
    local buf = file_buffer("fold1.org", { "* See [[file:dot.png]] here", "body", "* Next", "text" })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    images.show_links(buf, 1, 4)
    vim.cmd("1foldclose")
    images.sync()
    eq(1, pads(buf))
    local o = live()[1]
    ok(o, "an image is placed")
    eq({ 1, 1, 1 }, { o.row, o.width, o.height })
  end)

  -- Emacs 9.8.10 org-element-context: an unterminated block is a paragraph
  it("previews links after an unclosed #+begin_ line", function()
    local buf = file_buffer(
      "unterm.org",
      { "* A", "#+begin_example", "oops, never closed", "* B", "[[file:dog.png]]", "* C", "[[file:cat.png]]" }
    )
    eq({ 5, 7 }, rows_of(images.find_image_links(buf, 1, 100)))
  end)

  it("doesn't let an #+end_ line in a later section close a block", function()
    local buf =
      file_buffer("unterm2.org", { "* A", "#+begin_src c", "[[file:dog.png]]", "* B", "#+end_src", "[[file:cat.png]]" })
    eq({ 3, 6 }, rows_of(images.find_image_links(buf, 1, 100)))
  end)

  -- Emacs finds no link object in verbatim blocks, fixed-width lines or
  -- comments nested in a greater block; a verse block holds only objects
  it("reads the elements inside quote, center and special blocks", function()
    local cases = {
      { "#+begin_quote", "#+begin_src c", "[[file:dog.png]]", "#+end_src", "#+end_quote" },
      { "#+begin_quote", "#+begin_example", "[[file:dog.png]]", "#+end_example", "#+end_quote" },
      { "#+begin_center", "#+begin_comment", "[[file:dog.png]]", "#+end_comment", "#+end_center" },
      { "#+begin_note", "#+begin_export html", "[[file:dog.png]]", "#+end_export", "#+end_note" },
      { "#+begin_quote", ": [[file:dog.png]]", "#+end_quote" },
      { "#+begin_quote", "# [[file:dog.png]]", "#+end_quote" },
    }
    for i, lines_ in ipairs(cases) do
      local buf = file_buffer("nested" .. i .. ".org", lines_)
      eq({}, rows_of(images.find_image_links(buf, 1, 100)), table.concat(lines_, " / "))
    end
    local buf = file_buffer("quote.org", { "#+begin_quote", "[[file:dog.png]]", "#+end_quote" })
    eq({ 2 }, rows_of(images.find_image_links(buf, 1, 100)))
    buf = file_buffer("verse.org", { "#+begin_verse", "#+begin_src c", "[[file:dog.png]]", "#+end_src", "#+end_verse" })
    eq({ 3 }, rows_of(images.find_image_links(buf, 1, 100)))
  end)
end)
