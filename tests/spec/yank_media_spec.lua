-- org-yank-image-* and org-yank-dnd-*: pasting clipboard images and
-- dropped files. The clipboard is a fake wl-paste (not installed here) on a
-- fake Wayland display. Inserted links follow Emacs 9.8.10
-- (org--image-yank-media-handler, org--dnd-local-file-handler probes).
local config = require("org.config")
local utils = require("org.utils")
local yank = require("org.yank")
local ui = require("org.ui")
vim.g.org_test = true

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir)
end

local saved_env = {}

--- A fake wl-paste serving `types` (list) with `contents` (type -> text).
local function fake_clipboard(dir, types, contents)
  local bin = dir .. "/bin"
  vim.fn.mkdir(bin, "p")
  local lines = {
    "#!/bin/sh",
    'if [ "$1" = "--list-types" ]; then',
    "cat <<'EOF'",
  }
  vim.list_extend(lines, types)
  vim.list_extend(lines, { "EOF", "exit 0", "fi", 'case "$3" in' })
  for t, text in pairs(contents) do
    local f = bin .. "/" .. t:gsub("[^%w]", "_")
    utils.writefile(f, vim.split(text, "\n", { plain = true }))
    lines[#lines + 1] = string.format("%s) cat '%s';;", t, f)
  end
  vim.list_extend(lines, { "esac" })
  utils.writefile(bin .. "/wl-paste", lines)
  vim.fn.setfperm(bin .. "/wl-paste", "rwxr-xr-x")
  saved_env = { PATH = vim.env.PATH, WAYLAND_DISPLAY = vim.env.WAYLAND_DISPLAY }
  vim.env.PATH = bin .. ":" .. vim.env.PATH
  vim.env.WAYLAND_DISPLAY = "wayland-test"
end

local function org_file(dir, extra)
  config.setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    id = { locations_file = dir .. "/ids.json" },
    tags_column = 0,
  }, extra or {}))
  require("org.id")._reset()
  local p = dir .. "/notes.org"
  utils.writefile(p, { "* Task", ":PROPERTIES:", ":ID: abcdef", ":END:", "" })
  vim.cmd("edit! " .. p)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  return vim.api.nvim_get_current_buf()
end

describe("yank_media (org-yank-image-*)", function()
  after_each(function()
    vim.env.PATH, vim.env.WAYLAND_DISPLAY = saved_env.PATH, saved_env.WAYLAND_DISPLAY
    config.setup({})
  end)

  it("saves a clipboard image into a directory and links it", function()
    local dir = tmpdir()
    fake_clipboard(dir, { "text/plain", "image/png" }, { ["image/png"] = "PNGDATA" })
    local buf = org_file(dir, {
      yank = {
        image_save_method = "img/",
        image_file_name_function = function()
          return "shot"
        end,
      },
    })
    ok(yank.yank_media())
    -- Emacs: [[file:img/shot.png]]
    eq("[[file:img/shot.png]]", vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1])
    eq({ "PNGDATA" }, utils.readfile(dir .. "/img/shot.png"))
  end)

  it("attaches a clipboard image by default", function()
    local dir = tmpdir()
    fake_clipboard(dir, { "image/jpeg" }, { ["image/jpeg"] = "JPG" })
    local buf = org_file(dir, {
      yank = {
        image_file_name_function = function()
          return "shot2"
        end,
      },
    })
    ok(yank.yank_media())
    -- Emacs: [[attachment:shot2.jpeg][shot2.jpeg]] and the ATTACH tag
    eq("[[attachment:shot2.jpeg][shot2.jpeg]]", vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1])
    eq("* Task :ATTACH:", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    eq({ "JPG" }, utils.readfile(dir .. "/data/ab/cdef/shot2.jpeg"))
  end)

  it("names images clipboard-<time stamp> and declines without an image", function()
    local dir = tmpdir()
    fake_clipboard(dir, { "image/png" }, { ["image/png"] = "X" })
    local buf = org_file(dir, { yank = { image_save_method = dir .. "/pics" } })
    ok(yank.yank_media())
    ok(vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]:match("^%[%[file:pics/clipboard%-%d+T%d+%.%d%d%d%d%d%d%.png%]%]$"))
    fake_clipboard(dir, { "text/plain" }, { ["text/plain"] = "hello" })
    eq(false, yank.yank_media())
  end)

  it("handles files copied in a file manager", function()
    local dir = tmpdir()
    utils.writefile(dir .. "/a.txt", { "a" })
    fake_clipboard(dir, { "x-special/gnome-copied-files" }, {
      ["x-special/gnome-copied-files"] = "copy\nfile://" .. dir .. "/a.txt",
    })
    local buf = org_file(dir, { yank = { dnd_method = "attach" } })
    ok(yank.yank_media())
    -- Emacs: [[attachment:a.txt]] (a single file: no separator)
    eq("[[attachment:a.txt]]", vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1])
    ok(utils.exists(dir .. "/a.txt"))
  end)
end)

describe("dropped files (org-yank-dnd-*)", function()
  after_each(function()
    config.setup({})
  end)

  it("parses what terminals paste for dropped files", function()
    local dir = tmpdir()
    utils.writefile(dir .. "/a b.txt", { "x" })
    utils.writefile(dir .. "/c.png", { "x" })
    eq({ dir .. "/a b.txt", dir .. "/c.png" }, yank.parse_dropped(dir .. "/a\\ b.txt " .. dir .. "/c.png"))
    eq({ dir .. "/a b.txt" }, yank.parse_dropped("'" .. dir .. "/a b.txt'"))
    eq({ dir .. "/a b.txt" }, yank.parse_dropped("file://" .. dir .. "/a%20b.txt\n"))
    eq(nil, yank.parse_dropped("just some text"))
    eq(nil, yank.parse_dropped(dir .. "/missing.txt"))
  end)

  it("inserts file links, a space after each of several", function()
    local dir = tmpdir()
    utils.writefile(dir .. "/other.txt", { "x" })
    utils.writefile(dir .. "/pic.png", { "x" })
    local buf = org_file(dir, { yank = { dnd_method = "file-link" } })
    ok(yank.handle_files({ dir .. "/other.txt", dir .. "/pic.png" }, "copy"))
    -- Emacs: "[[/abs/other.txt]] [[/abs/pic.png]] "
    eq("[[" .. dir .. "/other.txt]] [[" .. dir .. "/pic.png]] ", vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1])
  end)

  it("attaches, sending images to the image directory", function()
    local dir = tmpdir()
    utils.writefile(dir .. "/other.txt", { "x" })
    utils.writefile(dir .. "/pic.png", { "x" })
    local buf = org_file(dir, { yank = { dnd_method = "attach", image_save_method = "imgs/" } })
    ok(yank.handle_file(dir .. "/other.txt", "copy"))
    vim.api.nvim_buf_set_lines(buf, 5, 5, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    ok(yank.handle_file(dir .. "/pic.png", "copy"))
    -- Emacs: "[[attachment:other.txt]] " and "[[file:imgs/pic.png]] "
    eq("[[attachment:other.txt]] ", vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1])
    eq("[[file:imgs/pic.png]] ", vim.api.nvim_buf_get_lines(buf, 5, 6, false)[1])
    ok(utils.exists(dir .. "/imgs/pic.png"))
    ok(utils.exists(dir .. "/data/ab/cdef/other.txt"))
  end)

  it("asks by default; a drop pasted in an Org buffer is handled, cancel pastes the text", function()
    local dir = tmpdir()
    utils.writefile(dir .. "/drop.txt", { "x" })
    local buf = org_file(dir, { yank = { dnd_default_attach_method = "mv" } })
    local orig = ui.menu
    local titles = {}
    local answer = { "attach" }
    ui.menu = function(opts)
      titles[#titles + 1] = opts.title
      return table.remove(answer, 1)
    end
    vim.paste({ dir .. "/drop.txt" }, -1)
    eq({ "What to do with file?" }, titles)
    eq("[[attachment:drop.txt]]", vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1])
    eq(false, utils.exists(dir .. "/drop.txt")) -- moved (dnd_default_attach_method)
    -- cancelled: the text is pasted
    utils.writefile(dir .. "/keep.txt", { "x" })
    vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.paste({ dir .. "/keep.txt" }, -1)
    ui.menu = orig
    ok(vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]:find(dir .. "/keep.txt", 1, true))
  end)
end)
