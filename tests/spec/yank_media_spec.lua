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
  fake_exe(bin, "wl-paste", table.concat(lines, "\n"))
  saved_env = { PATH = vim.env.PATH, WAYLAND_DISPLAY = vim.env.WAYLAND_DISPLAY }
  path_prepend(bin)
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
    local line = vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]
    ok(line:match("^%[%[file:pics/clipboard%-%d+T%d+%.%d%d%d%d%d%d%.png%]%]$"))
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

describe("yank_media on Windows", function()
  local real_has, real_executable, real_system, env
  local scripts

  -- the script of a powershell -EncodedCommand (UTF-16LE base64)
  local function decode(b64)
    local bytes, chars = vim.base64.decode(b64), {}
    for i = 1, #bytes, 2 do
      chars[#chars + 1] = bytes:byte(i) + bytes:byte(i + 1) * 256
    end
    return vim.fn.list2str(chars, 1)
  end

  before_each(function()
    real_has, real_executable, real_system = vim.fn.has, vim.fn.executable, vim.system
    env = { WAYLAND_DISPLAY = vim.env.WAYLAND_DISPLAY, DISPLAY = vim.env.DISPLAY }
    vim.env.WAYLAND_DISPLAY, vim.env.DISPLAY = nil, nil
    vim.fn.has = function(f)
      if f == "win32" then
        return 1
      elseif f == "mac" then
        return 0
      end
      return real_has(f)
    end
    vim.fn.executable = function(exe)
      return exe == "powershell.exe" and 1 or 0
    end
    scripts = {}
  end)

  after_each(function()
    vim.fn.has, vim.fn.executable, vim.system = real_has, real_executable, real_system
    vim.env.WAYLAND_DISPLAY, vim.env.DISPLAY = env.WAYLAND_DISPLAY, env.DISPLAY
    config.setup({})
  end)

  --- Answer each powershell.exe call with the first of `replies` whose
  --- pattern its script contains.
  local function powershell(replies)
    vim.system = function(cmd)
      eq("powershell.exe", cmd[1])
      eq("-STA", cmd[2])
      local script = decode(cmd[#cmd])
      scripts[#scripts + 1] = script
      for _, r in ipairs(replies) do
        if script:find(r[1], 1, true) then
          return {
            wait = function()
              if type(r[2]) == "function" then
                r[2](script)
              end
              return { code = 0, stdout = type(r[2]) == "string" and r[2] or "" }
            end,
          }
        end
      end
      error("unexpected script: " .. script)
    end
  end

  it("saves a clipboard image read through powershell.exe", function()
    local dir = tmpdir()
    local buf = org_file(dir, {
      yank = {
        image_save_method = "img/",
        image_file_name_function = function()
          return "shot"
        end,
      },
    })
    powershell({
      { "ContainsImage()", "image/png\r\n" },
      {
        "GetImage()",
        function(script)
          -- the script saves the PNG to the path it names
          local path = script:match("Save%('([^']+)'")
          utils.writefile(path, { "PNGDATA" })
        end,
      },
    })
    ok(yank.yank_media())
    eq("[[file:img/shot.png]]", vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1])
    eq({ "PNGDATA" }, utils.readfile(dir .. "/img/shot.png"))
  end)

  it("moves files cut in Explorer, with Windows file URIs", function()
    local dir = tmpdir()
    utils.writefile(dir .. "/cut me.txt", { "x" })
    local buf = org_file(dir, { yank = { dnd_method = "file-link" } })
    local uri = "file:///" .. dir:gsub("^/", "") .. "/cut%20me.txt"
    powershell({
      { "ContainsImage()", "x-special/win-copied-files\r\n" },
      { "Preferred DropEffect", "cut\r\n" .. uri .. "\r\n" },
    })
    ok(yank.yank_media())
    ok(vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]:find("cut me.txt", 1, true))
  end)

  it("reads quoted Windows paths of dropped files, with backslashes", function()
    if real_has("win32") == 0 then
      return -- only Windows turns the backslashes of a path into slashes
    end
    local dir = tmpdir()
    utils.writefile(dir .. "/a b.txt", { "x" })
    -- a backslash is a directory separator here, not an escape
    local win = dir:gsub("/", "\\")
    eq({ dir .. "/a b.txt" }, yank.parse_dropped('"' .. win .. '\\a b.txt"'))
  end)
end)
