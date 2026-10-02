local utils = require("org.utils")

describe("Windows paths", function()
  local saved_home

  before_each(function()
    saved_home = vim.env.HOME
  end)

  after_each(function()
    vim.env.HOME = saved_home
  end)

  it("knows absolute paths with a drive or a UNC share", function()
    for _, p in ipairs({ "/x", "C:/notes/a.org", "c:\\notes\\a.org", "\\\\server\\share\\a.org", "//server/share" }) do
      ok(utils.is_absolute(p), p)
    end
    for _, p in ipairs({ "a.org", "notes/a.org", "./a.org", "../a.org", "~/a.org", "C:a.org", "notes\\a.org" }) do
      ok(not utils.is_absolute(p), p)
    end
  end)

  it("keeps a drive path absolute when expanding", function()
    eq("C:/notes/todo.org", utils.expand("C:/notes/todo.org", "/base"))
    -- vim.fs.normalize turns \ into / only on Windows
    local back = utils.expand("C:\\notes\\todo.org", "/base")
    eq(vim.fn.has("win32") == 1 and "C:/notes/todo.org" or "C:\\notes\\todo.org", back)
    eq("/base/todo.org", utils.expand("todo.org", "/base"))
  end)

  it("finds the home directory without $HOME", function()
    vim.env.HOME = nil
    local home = utils.home()
    eq(vim.uv.os_homedir():gsub("\\", "/"), home)
    eq(home .. "/org/todo.org", utils.expand("~/org/todo.org"))
  end)

  it("uses forward slashes for a Windows-style $HOME", function()
    vim.env.HOME = "C:\\Users\\me"
    eq("C:/Users/me", utils.home())
    eq("C:/Users/me/org", utils.expand("~/org"))
  end)

  it("exports a file link with a drive as a file link", function()
    local file_uri = require("org.export.ox").file_uri
    eq("a.org", file_uri("a.org"))
    -- a drive is a drive only on Windows (fnamemodify ":p")
    if vim.fn.has("win32") == 1 then
      eq("file:///C:/notes/a.org", file_uri("C:/notes/a.org"))
    end
  end)
end)
