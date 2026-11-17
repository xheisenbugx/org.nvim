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

  it("takes a directory another process made while it tried again", function()
    -- CI on PR #345: six parallel `org capture` failed with E739 on the
    -- state directory: the first mkdir() lost the race on a parent, the
    -- second on the directory itself
    local dir = vim.fn.tempname() .. "/a/b"
    local real = vim.fn.mkdir
    local calls = 0
    vim.fn.mkdir = function(d, flags)
      calls = calls + 1
      if calls == 1 then
        real(vim.fs.dirname(d), flags)
        error("Vim:E739: Cannot create directory " .. vim.fs.dirname(d) .. ": file already exists")
      end
      real(d, flags)
      error("Vim:E739: Cannot create directory " .. d .. ": file already exists")
    end
    local ok, err = pcall(require("org.utils").mkdir_p, dir)
    vim.fn.mkdir = real
    assert(ok, err)
    eq(1, vim.fn.isdirectory(dir))
    vim.fn.delete(vim.fs.dirname(vim.fs.dirname(dir)), "rf")
  end)

  it("still fails when the directory can't be made", function()
    local file = vim.fn.tempname()
    vim.fn.writefile({}, file)
    local ok = pcall(require("org.utils").mkdir_p, file .. "/sub")
    eq(false, ok)
    vim.fn.delete(file)
  end)
end)

describe("utils.glob_org_files: names with wildcard characters and commas", function()
  local dir
  before_each(function()
    dir = vim.fs.normalize(vim.fn.tempname())
    for _, f in ipairs({ "plan[1].org", "plan1.org", "[work] notes/a.org", "Notes, 2024/b.org" }) do
      utils.writefile(dir .. "/" .. f, { "* T" })
    end
  end)

  it("finds a file whose name holds [ ]", function()
    eq({ dir .. "/plan[1].org" }, utils.glob_org_files({ dir .. "/plan[1].org" }))
  end)

  it("finds the files of a directory whose name holds [ ] or a comma", function()
    eq({ dir .. "/[work] notes/a.org" }, utils.glob_org_files({ dir .. "/[work] notes" }))
    eq({ dir .. "/Notes, 2024/b.org" }, utils.glob_org_files({ dir .. "/Notes, 2024" }))
  end)

  it("globs below such a directory", function()
    eq({ dir .. "/[work] notes/a.org" }, utils.glob_org_files({ dir .. "/[work] notes/*.org" }))
    eq({ dir .. "/Notes, 2024/b.org" }, utils.glob_org_files({ dir .. "/Notes, 2024/*.org" }))
  end)

  it("still globs: * ? [..] {a,b} and **", function()
    eq({ dir .. "/plan1.org", dir .. "/plan[1].org" }, utils.glob_org_files({ dir .. "/plan*.org" }))
    eq({ dir .. "/plan1.org" }, utils.glob_org_files({ dir .. "/plan[0-9].org" }))
    eq({ dir .. "/plan1.org" }, utils.glob_org_files({ dir .. "/plan?.org" }))
    eq({ dir .. "/plan1.org" }, utils.glob_org_files({ dir .. "/{plan1,none}.org" }))
    eq(
      { dir .. "/Notes, 2024/b.org", dir .. "/[work] notes/a.org", dir .. "/plan1.org", dir .. "/plan[1].org" },
      utils.glob_org_files({ dir .. "/**/*.org" })
    )
  end)
end)

describe("utils.glob", function()
  local dir
  before_each(function()
    dir = vim.fs.normalize(vim.fn.tempname())
    for _, f in ipairs({ "a.org", ".hidden.org", "sub/b.org", "sub/deep/c.org", ".git/d.org" }) do
      utils.writefile(dir .. "/" .. f, { "x" })
    end
  end)

  it("matches like Vim's glob(): dotfiles only for a dot pattern, ** skips hidden directories", function()
    eq({ dir .. "/a.org" }, utils.glob(dir .. "/*.org"))
    eq({ dir .. "/.hidden.org" }, utils.glob(dir .. "/.*.org"))
    eq({ dir .. "/a.org", dir .. "/sub/b.org", dir .. "/sub/deep/c.org" }, utils.glob(dir .. "/**/*.org"))
    eq({ dir .. "/sub" }, utils.glob(dir .. "/s*"))
    eq({}, utils.glob(dir .. "/nothing*"))
    eq({}, utils.glob(dir .. "/missing/*.org"))
  end)

  it("starts at a drive's root for C:/*.org, not at drive C's current directory", function()
    local parts, k, base = utils._glob_split("C:/*.org")
    eq({ { "C:", "*.org" }, 2, "C:/" }, { parts, k, base })
    eq("C:/x", select(3, utils._glob_split("C:/x/*.org")))
    eq("/", select(3, utils._glob_split("/*.org")))
    eq("//server/share", select(3, utils._glob_split("//server/share/*.org")))
    eq(nil, select(3, utils._glob_split("*.org")))
    eq({ "/", "C:/", "D:/x" }, { utils.dir_path(""), utils.dir_path("C:"), utils.dir_path("D:/x") })
  end)

  it("gives relative paths for a relative pattern", function()
    local cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    local got = utils.glob("sub/*.org")
    vim.cmd("cd " .. vim.fn.fnameescape(cwd))
    eq({ "sub/b.org" }, got)
  end)
end)
