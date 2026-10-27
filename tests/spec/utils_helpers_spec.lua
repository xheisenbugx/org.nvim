local utils = require("org.utils")

describe("utils small helpers", function()
  it("is_blank: empty, whitespace-only and missing lines", function()
    eq(true, utils.is_blank(""))
    eq(true, utils.is_blank("   \t"))
    eq(true, utils.is_blank("\r"))
    eq(true, utils.is_blank(nil))
    eq(false, utils.is_blank("  x "))
    eq(false, utils.is_blank("* H"))
  end)

  it("strip_quotes: removes one pair of surrounding double quotes", function()
    eq("a b", utils.strip_quotes('"a b"'))
    eq('"a"', utils.strip_quotes('""a""'))
    eq("", utils.strip_quotes('""'))
    eq('"', utils.strip_quotes('"'))
    eq("plain", utils.strip_quotes("plain"))
    eq(' "a"', utils.strip_quotes(' "a"'))
    eq('"a', utils.strip_quotes('"a'))
  end)

  it("link_descriptions: shows links as Org displays them", function()
    eq("see Desc here", utils.link_descriptions("see [[https://x.org][Desc]] here"))
    eq("go file:a.org", utils.link_descriptions("go [[file:a.org]]"))
    eq("A and b", utils.link_descriptions("[[x][A]] and [[b]]"))
    eq("no links", utils.link_descriptions("no links"))
    -- a single value, not gsub's count too
    eq(1, select("#", utils.link_descriptions("[[a]]")))
  end)

  it("read_text: whole file contents, nil when missing", function()
    local path = vim.fn.tempname()
    local fd = assert(io.open(path, "wb"))
    fd:write("one\r\ntwo\n\0bin")
    fd:close()
    eq("one\r\ntwo\n\0bin", utils.read_text(path, true))
    if vim.fn.has("win32") == 0 then
      eq("one\r\ntwo\n\0bin", utils.read_text(path))
    end
    os.remove(path)
    eq(nil, utils.read_text(path))
    eq(nil, utils.read_text(path, true))
    local empty = vim.fn.tempname()
    fd = assert(io.open(empty, "wb"))
    fd:close()
    eq("", utils.read_text(empty))
    os.remove(empty)
  end)
end)

describe("utils.mkdir_p", function()
  it("takes a directory another process made at the same time", function()
    local dir = vim.fn.tempname() .. "/a/b"
    local real = vim.fn.mkdir
    -- the other process wins the race: the directory appears, then
    -- mkdir() fails with E739
    vim.fn.mkdir = function(d, flags)
      real(d, flags)
      error("Vim:E739: Cannot create directory " .. d .. ": file already exists")
    end
    local ok, err = pcall(require("org.utils").mkdir_p, dir)
    vim.fn.mkdir = real
    assert(ok, err)
    eq(1, vim.fn.isdirectory(dir))
    -- and there already: nothing to do
    require("org.utils").mkdir_p(dir)
    vim.fn.delete(vim.fs.dirname(vim.fs.dirname(dir)), "rf")
  end)
end)
