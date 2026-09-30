-- Inserted (materialized) transclusions must never reach a file, whatever
-- writes the buffer and whatever edits, undo and redo did before.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function setup(t)
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
    extensions = t ~= nil and { transclusion = t } or nil,
  })
end

local T = require("org.extensions.transclusion")
local api = vim.api

local dir

local function write(name, lines)
  vim.fn.writefile(lines, dir .. "/" .. name)
  return dir .. "/" .. name
end

local NOTES = {
  "* Notes",
  "#+transclude: [[file:src.org::*Beta]]",
  "Between",
  "#+transclude: [[file:code.py]] :lines 1-2",
  "Tail",
}

-- the inserted text of NOTES
local BETA = { "* Beta", "b1", "b2" }
local CODE = { "import os", "x = 1" }

local function open(lines, name)
  local path = write(name or "notes.org", lines or NOTES)
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  local buf = api.nvim_get_current_buf()
  T.add_all(buf)
  return buf, path
end

local function changed(buf)
  api.nvim_exec_autocmds("TextChanged", { buffer = buf })
end

-- end the undo block, as between two commands typed by hand
local function sync()
  vim.cmd("let &undolevels = &undolevels")
end

local function quiet(fn)
  local notify = vim.notify
  local msgs = {}
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  if not ok then
    error(err, 0)
  end
  return msgs
end

local function shown()
  local out = vim.deepcopy(NOTES)
  table.insert(out, 3, BETA[1])
  table.insert(out, 4, BETA[2])
  table.insert(out, 5, BETA[3])
  table.insert(out, 8, CODE[1])
  table.insert(out, 9, CODE[2])
  return out
end

describe("transclusion data safety", function()
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write("src.org", { "* Beta", "b1", "b2", "* Other", "o" })
    write("code.py", { "import os", "x = 1", "y = 2" })
    setup({ watch = false, debounce = 1, mode = "virtual" })
  end)

  after_each(function()
    setup()
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
  end)

  it("shows the text in the buffer and keeps the file clean on :w", function()
    local buf, path = open()
    eq(shown(), buf_lines(buf))
    vim.cmd("silent write")
    eq(NOTES, vim.fn.readfile(path))
    eq(shown(), buf_lines(buf))
    eq(false, vim.bo[buf].modified)
    eq(2, #T.regions(buf))
  end)

  it(":w otherfile writes the clean text and keeps the modified flag", function()
    local buf, path = open()
    api.nvim_buf_set_lines(buf, 0, 1, false, { "* Notes!" })
    vim.cmd("silent write " .. dir .. "/other.org")
    local want = vim.deepcopy(NOTES)
    want[1] = "* Notes!"
    eq(want, vim.fn.readfile(dir .. "/other.org"))
    eq(NOTES, vim.fn.readfile(path))
    eq(true, vim.bo[buf].modified)
    eq(2, #T.regions(buf))
    vim.cmd("silent write")
    eq(want, vim.fn.readfile(path))
    eq(false, vim.bo[buf].modified)
  end)

  it(":w >> file appends only the keywords", function()
    local buf = open()
    write("log.org", { "before" })
    vim.cmd("silent write >> " .. dir .. "/log.org")
    eq(vim.list_extend({ "before" }, vim.deepcopy(NOTES)), vim.fn.readfile(dir .. "/log.org"))
    eq(shown(), buf_lines(buf))
  end)

  it("a partial write (:[range]w) leaves the inserted lines of the range out", function()
    local buf = open()
    -- lines 2..6: the keyword, Beta's three lines and "Between"
    vim.cmd("silent 2,6write " .. dir .. "/part.org")
    eq({ NOTES[2], "Between" }, vim.fn.readfile(dir .. "/part.org"))
    eq(shown(), buf_lines(buf))
    -- a range starting inside inserted text
    vim.cmd("silent 4,9write! " .. dir .. "/part.org")
    eq({ "Between", NOTES[4] }, vim.fn.readfile(dir .. "/part.org"))
    eq(shown(), buf_lines(buf))
    eq(2, #T.regions(buf))
  end)

  it(":saveas writes the clean text under the new name", function()
    local buf, path = open()
    vim.cmd("silent saveas " .. dir .. "/renamed.org")
    eq(NOTES, vim.fn.readfile(dir .. "/renamed.org"))
    eq(NOTES, vim.fn.readfile(path))
    eq(shown(), buf_lines(buf))
    eq(false, vim.bo[buf].modified)
  end)

  it("puts the text back when another BufWritePre stops the write", function()
    local buf, path = open()
    local au = api.nvim_create_autocmd("BufWritePre", {
      buffer = buf,
      callback = function()
        error("formatter failed")
      end,
    })
    api.nvim_buf_set_lines(buf, 0, 1, false, { "* Unsaved" })
    ok(not pcall(vim.cmd, "silent write"))
    api.nvim_del_autocmd(au)
    vim.wait(1000, function()
      return #T.regions(buf) == 2
    end)
    eq(NOTES, vim.fn.readfile(path))
    local want = shown()
    want[1] = "* Unsaved"
    eq(want, buf_lines(buf))
    eq(true, vim.bo[buf].modified)
    -- and it is still protected and saved clean afterwards
    vim.cmd("silent write")
    eq("* Unsaved", vim.fn.readfile(path)[1])
    eq(#NOTES, #vim.fn.readfile(path))
  end)

  it("puts the text back when the file can't be written", function()
    local buf, path = open()
    api.nvim_buf_set_lines(buf, 0, 1, false, { "* Unsaved" })
    -- E212: the directory doesn't exist (BufWritePre ran, BufWritePost won't)
    ok(not pcall(vim.cmd, "silent write " .. dir .. "/no/such/dir/x.org"))
    vim.wait(1000, function()
      return #T.regions(buf) == 2
    end)
    eq(NOTES, vim.fn.readfile(path))
    local want = shown()
    want[1] = "* Unsaved"
    eq(want, buf_lines(buf))
    eq(true, vim.bo[buf].modified)
    eq(2, #T.regions(buf))
  end)

  it("doesn't put the text back while a formatter waits inside BufWritePre", function()
    local buf, path = open()
    -- like conform.nvim formatting with an LSP: vim.wait() in BufWritePre
    -- after this extension's handler runs the event loop
    local seen
    local au = api.nvim_create_autocmd("BufWritePre", {
      buffer = buf,
      callback = function()
        vim.wait(60)
        seen = buf_lines(buf)
      end,
    })
    vim.cmd("silent write")
    api.nvim_del_autocmd(au)
    eq(NOTES, seen)
    eq(NOTES, vim.fn.readfile(path))
    eq(shown(), buf_lines(buf))
  end)

  it("keeps the file clean when a formatter rewrote the buffer before BufWritePre", function()
    -- a formatter registered before the extension replaces every line
    local fmt = api.nvim_create_autocmd("BufWritePre", {
      callback = function(ev)
        local lines = api.nvim_buf_get_lines(ev.buf, 0, -1, false)
        api.nvim_buf_set_lines(ev.buf, 0, -1, false, lines)
      end,
    })
    setup({ watch = false, debounce = 1 })
    local buf, path = open()
    vim.cmd("silent write")
    api.nvim_del_autocmd(fmt)
    eq(NOTES, vim.fn.readfile(path))
    eq(shown(), buf_lines(buf))
  end)

  it("heals a file written with :noautocmd", function()
    local buf, path = open()
    api.nvim_buf_set_lines(buf, 0, 1, false, { "* Changed" })
    vim.cmd("silent noautocmd write")
    -- nothing could stop that: the file holds the inserted text
    eq(shown()[3], vim.fn.readfile(path)[3])
    quiet(function()
      api.nvim_exec_autocmds("BufLeave", { buffer = buf })
    end)
    local want = vim.deepcopy(NOTES)
    want[1] = "* Changed"
    eq(want, vim.fn.readfile(path))
    eq(false, vim.bo[buf].modified)
    eq(2, #T.regions(buf))
  end)

  it("keeps the text out of org's own writes (refile, capture, archive, ...)", function()
    local buf, path = open()
    api.nvim_buf_set_lines(buf, 0, 1, false, { "* Saved by org" })
    assert(require("org.utils").save_buffer(buf))
    local want = vim.deepcopy(NOTES)
    want[1] = "* Saved by org"
    eq(want, vim.fn.readfile(path))
    want = shown()
    want[1] = "* Saved by org"
    eq(want, buf_lines(buf))
    eq(false, vim.bo[buf].modified)
  end)

  it("keeps CRLF files clean", function()
    local buf, path = open()
    vim.bo[buf].fileformat = "dos"
    vim.cmd("silent write")
    local fd = assert(io.open(path, "rb"))
    local raw = fd:read("*a")
    fd:close()
    eq(table.concat(NOTES, "\r\n") .. "\r\n", raw)
    eq(shown(), buf_lines(buf))
  end)

  it("never writes the text after undo, redo and :earlier across saves", function()
    local buf, path = open()
    sync()
    local function check()
      changed(buf)
      vim.cmd("silent write")
      sync()
      for _, l in ipairs(vim.fn.readfile(path)) do
        ok(l ~= "b1" and l ~= "import os", "inserted text in the file: " .. l)
      end
    end
    api.nvim_buf_set_lines(buf, 0, 1, false, { "* One" })
    check()
    api.nvim_buf_set_lines(buf, 0, 1, false, { "* Two" })
    check()
    vim.cmd("silent undo")
    check()
    vim.cmd("silent undo")
    check()
    vim.cmd("silent undo")
    check()
    vim.cmd("silent redo")
    check()
    vim.cmd("silent earlier 1f")
    check()
    vim.cmd("silent earlier 1f")
    check()
    vim.cmd("silent later 1f")
    check()
    -- the text stays shown and protected
    ok(#T.regions(buf) >= 1)
  end)

  it("brings back text deleted as a whole with undo, still protected", function()
    local buf, path = open()
    sync()
    vim.cmd("normal! 3G3dd")
    changed(buf)
    eq(1, #T.regions(buf))
    vim.cmd("silent undo")
    changed(buf)
    eq(2, #T.regions(buf))
    eq(NOTES, (T.clean_lines(buf)))
    vim.cmd("silent write")
    eq(NOTES, vim.fn.readfile(path))
  end)

  it("brings back text taken out by transclusion_remove with undo", function()
    local buf = open()
    sync()
    api.nvim_win_set_cursor(0, { 4, 0 })
    T.remove()
    eq(1, #T.regions(buf))
    vim.cmd("silent undo")
    changed(buf)
    eq(2, #T.regions(buf))
    eq(NOTES, (T.clean_lines(buf)))
  end)

  it("undo and redo of transclusion_add keep the marks with the text", function()
    local path = write("notes.org", NOTES)
    vim.cmd("edit! " .. path)
    local buf = api.nvim_get_current_buf()
    sync()
    api.nvim_win_set_cursor(0, { 2, 0 })
    T.add()
    sync()
    eq(1, #T.regions(buf))
    vim.cmd("silent undo")
    changed(buf)
    eq(NOTES, buf_lines(buf))
    eq(0, #T.regions(buf))
    vim.cmd("silent redo")
    changed(buf)
    eq(1, #T.regions(buf))
    eq(NOTES, (T.clean_lines(buf)))
  end)

  it("keeps the user's lines when the whole buffer is replaced", function()
    local buf, path = open()
    local new = { "* Notes!", NOTES[2], "User 1", "User 2", "User 3", "User 4", "User 5", "Tail" }
    api.nvim_buf_set_lines(buf, 0, -1, false, new)
    changed(buf)
    eq(new, buf_lines(buf))
    vim.cmd("silent write")
    eq(new, vim.fn.readfile(path))
  end)

  it("keeps lines typed or pasted inside the text, below it", function()
    local buf, path = open()
    -- o on the first inserted line
    api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("normal! otyped")
    quiet(function()
      changed(buf)
    end)
    local want = shown()
    table.insert(want, 6, "typed")
    eq(want, buf_lines(buf))
    -- a line pasted over an inserted line (Vp) is kept too
    vim.fn.setreg("a", "pasted\n", "l")
    api.nvim_win_set_cursor(0, { 4, 0 })
    vim.cmd('normal! V"ap')
    quiet(function()
      changed(buf)
    end)
    table.insert(want, 6, "pasted")
    eq(want, buf_lines(buf))
    vim.cmd("silent write")
    local disk = vim.deepcopy(NOTES)
    table.insert(disk, 3, "pasted")
    table.insert(disk, 4, "typed")
    eq(disk, vim.fn.readfile(path))
  end)

  it("keeps a line joined to the end of the text (J)", function()
    local buf, path = open()
    -- J on Beta's last line pulls "Between" into it
    api.nvim_win_set_cursor(0, { 5, 0 })
    vim.cmd("normal! J")
    quiet(function()
      changed(buf)
    end)
    eq(shown(), buf_lines(buf))
    vim.cmd("silent write")
    eq(NOTES, vim.fn.readfile(path))
    eq(shown(), buf_lines(buf))
    eq(2, #T.regions(buf))
  end)

  it("keeps the keyword when the first inserted line is joined to it", function()
    local buf, path = open()
    api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("normal! J")
    quiet(function()
      changed(buf)
    end)
    eq(shown(), buf_lines(buf))
    vim.cmd("silent write")
    eq(NOTES, vim.fn.readfile(path))
    eq(shown(), buf_lines(buf))
    eq(2, #T.regions(buf))
  end)

  it("survives random edits, undo and writes without leaking", function()
    local buf, path = open()
    sync()
    local seed = tonumber(vim.env.ORG_FUZZ_SEED or "") or 7
    local function rand(n)
      seed = (seed * 1103515245 + 12345) % 2147483648
      return seed % n + 1
    end
    vim.fn.setreg("a", "pasted\n", "l")
    local ops = {
      '"_dd',
      "J",
      "otyped\27",
      "Otyped above\27",
      "x",
      "ccchanged\27",
      ">>",
      '"ap',
      '"aP',
      "u",
      "\18",
      "2u",
      '"_2dd',
      "gJ",
      'V"ap',
      ":m+1\r",
      ":m-2\r",
    }
    local markers = { ["b1"] = true, ["b2"] = true, ["import os"] = true, ["x = 1"] = true, ["* Beta"] = true }
    for step = 1, 600 do
      if step % 50 == 0 and #T.regions(buf) == 0 then
        -- everything was deleted: start again
        api.nvim_buf_set_lines(buf, 0, -1, false, NOTES)
        T.add_all(buf)
        sync()
      end
      local n = api.nvim_buf_line_count(buf)
      api.nvim_win_set_cursor(0, { rand(n), 0 })
      quiet(function()
        pcall(vim.cmd, "silent normal! " .. ops[rand(#ops)])
        changed(buf)
      end)
      sync()
      if step % 10 == 0 then
        local clean = T.clean_lines(buf)
        quiet(function()
          vim.cmd("silent write")
        end)
        local disk = vim.fn.readfile(path)
        if #clean == 1 and clean[1] == "" and #disk == 0 then
          disk = { "" } -- an emptied buffer writes an empty file
        end
        eq(clean, disk)
        for _, l in ipairs(disk) do
          ok(not markers[vim.trim(l)], "inserted text in the file at step " .. step .. ": " .. l)
        end
        -- every marked line is inserted text: nothing of the user's is hidden
        for _, r in ipairs(T.ranges(buf)) do
          for i = r.first, r.last do
            local l = buf_lines(buf)[i]
            ok(markers[vim.trim(l or "")] or l == "", "a user line is marked at step " .. step .. ": " .. tostring(l))
          end
        end
      end
    end
  end)

  it("keeps a source's own inserted text out when the edit float writes it", function()
    -- src.org, loaded, has an inserted transclusion of code.py
    local sbuf = open({ "* Beta", "b1", "#+transclude: [[file:code.py]] :lines 1-1", "b2" }, "src.org")
    eq("import os", buf_lines(sbuf)[4])
    local buf = open()
    api.nvim_win_set_cursor(0, { 3, 0 })
    local eb = T.edit()
    api.nvim_buf_set_lines(eb, 1, 2, false, { "b1, edited" })
    vim.cmd("silent write")
    eq(
      { "* Beta", "b1, edited", "#+transclude: [[file:code.py]] :lines 1-1", "b2" },
      vim.fn.readfile(dir .. "/src.org")
    )
    eq("import os", buf_lines(sbuf)[4])
    eq(false, vim.bo[sbuf].modified)
    vim.cmd.normal(vim.keycode("<Esc>"))
    eq(buf, api.nvim_get_current_buf())
  end)

  it("writes clean with :wq", function()
    local path = write("notes.org", NOTES)
    local init = root .. "/tests/minimal_init.lua"
    local script = table.concat({
      "require('org').setup({ extensions = { transclusion = { mode = 'materialized', watch = false } } })",
      "vim.cmd('edit " .. path .. "')",
      "assert(#require('org.extensions.transclusion').regions(0) == 2)",
      "vim.api.nvim_buf_set_lines(0, 0, 1, false, { '* Quit' })",
      "vim.cmd('wq')",
    }, "\n")
    local lua = write("run.lua", vim.split(script, "\n"))
    local res = vim.system({ vim.v.progpath, "--headless", "-u", init, "-c", "luafile " .. lua }):wait(20000)
    eq(0, res.code)
    local want = vim.deepcopy(NOTES)
    want[1] = "* Quit"
    eq(want, vim.fn.readfile(path))
  end)
end)
