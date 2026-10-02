local files = require("org.files")

describe("parsed buffer cache", function()
  it("reparses renamed buffers even when their text did not change", function()
    local buf = org_buffer({ "* Task" })
    local before = vim.fn.tempname() .. ".org"
    local after = vim.fn.tempname() .. ".org"
    vim.api.nvim_buf_set_name(buf, before)
    local original = files.get_buffer(buf)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    eq(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)), original.filename)
    vim.api.nvim_buf_set_name(buf, after)
    eq(tick, vim.api.nvim_buf_get_changedtick(buf))
    local renamed = files.get_buffer(buf)
    eq(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)), renamed.filename)
    eq(renamed, files.get(renamed.filename))
    eq(renamed, renamed.headlines[1].file)
  end)

  it("reparses a cached unnamed buffer after its first filename is assigned", function()
    local buf = org_buffer({ "* Task" })
    eq(nil, files.get_buffer(buf).filename)
    local name = vim.fn.tempname() .. ".org"
    vim.api.nvim_buf_set_name(buf, name)
    eq(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)), files.get_buffer(buf).filename)
  end)
end)

describe("files read from disk", function()
  local function write(path, text)
    local fd = assert(io.open(path, "wb"))
    fd:write(text)
    fd:close()
  end

  -- a file system with coarse timestamps keeps the mtime across a rewrite
  local function fix_mtime(path)
    vim.uv.fs_utime(path, 1700000000, 1700000000)
  end

  it("ignores a UTF-8 byte order mark like the buffer does", function()
    local path = vim.fn.tempname() .. ".org"
    write(path, "\239\187\191#+TITLE: T\r\n* Head\r\n")
    local f = files.get(path)
    eq(1, #f.headlines)
    eq("Head", f.headlines[1].title)
    eq("T", f.settings.title)
  end)

  it("reparses a file rewritten within the same mtime", function()
    local path = vim.fn.tempname() .. ".org"
    write(path, "* One\n")
    fix_mtime(path)
    eq(1, #files.get(path).headlines)
    write(path, "* One\n* Two\n")
    fix_mtime(path)
    eq(2, #files.get(path).headlines)
  end)

  it("drops the cached parse when org writes the file", function()
    local path = vim.fn.tempname() .. ".org"
    write(path, "* One\n")
    fix_mtime(path)
    eq(1, #files.get(path).headlines)
    require("org.utils").writefile(path, { "* Uno" })
    fix_mtime(path)
    eq("Uno", files.get(path).headlines[1].title)
  end)
end)
