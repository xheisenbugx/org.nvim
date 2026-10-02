local attach = require("org.attach")
local attach_git = require("org.attach_git")
local config = require("org.config")
local utils = require("org.utils")
vim.g.org_test = true

local initial = { org_directory = config.opts.org_directory, agenda_files = config.opts.agenda_files }

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return require("org.utils").realpath(dir)
end

local function run(args, cwd)
  local res = vim.system(args, { cwd = cwd, text = true }):wait()
  return vim.trim(res.stdout or ""), res.code
end

local function git_init(dir)
  vim.fn.mkdir(dir, "p")
  run({ "git", "init", "-q" }, dir)
  run({ "git", "config", "user.email", "test@example.com" }, dir)
  run({ "git", "config", "user.name", "Test" }, dir)
  run({ "git", "config", "commit.gpgsign", "false" }, dir)
end

local function setup(dir, extra)
  config.setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    agenda_files = { dir .. "/*.org" },
    id = { locations_file = dir .. "/ids.json" },
    tags_column = 0,
    attach = { git = true },
  }, extra or {}))
  require("org.id")._reset()
end

local function file_buffer(dir, lines)
  local p = dir .. "/a.org"
  utils.writefile(p, lines)
  vim.cmd("edit! " .. p)
  return vim.api.nvim_get_current_buf()
end

describe("org-attach-git", function()
  if vim.fn.executable("git") == 0 then
    return
  end
  local buf
  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    config.setup(initial)
  end)

  it("commits attachments added, synced and deleted in the attachment root", function()
    local dir = tmpdir()
    setup(dir)
    git_init(dir .. "/data")
    buf = file_buffer(dir, { "* Task", ":PROPERTIES:", ":ID: abcdef", ":END:" })
    local t = { bufnr = buf, lnum = 1 }
    utils.writefile(dir .. "/x.txt", { "x" })
    attach.attach_file(dir .. "/x.txt", "cp", t)
    eq("ab/cdef/x.txt", run({ "git", "ls-files" }, dir .. "/data"))
    eq("Synchronized attachments", run({ "git", "log", "-1", "--format=%s" }, dir .. "/data"))
    eq("", run({ "git", "status", "--porcelain" }, dir .. "/data"))
    -- a file added outside org-attach is committed by a sync
    utils.writefile(dir .. "/data/ab/cdef/y.txt", { "y" })
    attach.sync(t)
    eq("ab/cdef/x.txt\nab/cdef/y.txt", run({ "git", "ls-files" }, dir .. "/data"))
    eq("2", run({ "git", "rev-list", "--count", "HEAD" }, dir .. "/data"))
    attach.delete_all(t, true)
    eq("", run({ "git", "ls-files" }, dir .. "/data"))
    eq("3", run({ "git", "rev-list", "--count", "HEAD" }, dir .. "/data"))
  end)

  it("does nothing unless attach.git is on or outside a repository", function()
    local dir = tmpdir()
    setup(dir, { attach = { git = false } })
    git_init(dir .. "/data")
    buf = file_buffer(dir, { "* Task", ":PROPERTIES:", ":ID: abcdef", ":END:" })
    utils.writefile(dir .. "/x.txt", { "x" })
    attach.attach_file(dir .. "/x.txt", "cp", { bufnr = buf, lnum = 1 })
    eq("", run({ "git", "ls-files" }, dir .. "/data"))
    local plain = tmpdir()
    eq(nil, attach_git.commit(plain))
  end)

  it("uses the entry's own repository with git_dir = individual-repository", function()
    local dir = tmpdir()
    setup(dir, { attach = { git_dir = "individual-repository" } })
    git_init(dir .. "/data/ab/cdef")
    buf = file_buffer(dir, { "* Task", ":PROPERTIES:", ":ID: abcdef", ":END:" })
    utils.writefile(dir .. "/x.txt", { "x" })
    attach.attach_file(dir .. "/x.txt", "cp", { bufnr = buf, lnum = 1 })
    eq("x.txt", run({ "git", "ls-files" }, dir .. "/data/ab/cdef"))
  end)

  it("commits and removes attachments whose names start with a dash", function()
    local dir = tmpdir()
    setup(dir, { attach = { git_dir = "individual-repository" } })
    git_init(dir .. "/data/ab/cdef")
    buf = file_buffer(dir, { "* Task", ":PROPERTIES:", ":ID: abcdef", ":END:" })
    utils.writefile(dir .. "/-n.txt", { "x" })
    attach.attach_file(dir .. "/-n.txt", "cp", { bufnr = buf, lnum = 1 })
    eq("-n.txt", run({ "git", "ls-files" }, dir .. "/data/ab/cdef"))
    vim.uv.fs_unlink(dir .. "/data/ab/cdef/-n.txt")
    eq(1, attach_git.commit(dir .. "/data/ab/cdef"))
    eq("", run({ "git", "ls-files" }, dir .. "/data/ab/cdef"))
  end)

  it("annexes large files and gets missing annexed content", function()
    if vim.fn.executable("git-annex") == 0 then
      return
    end
    local dir = tmpdir()
    setup(dir, { attach = { git_annex_cutoff = 10, git_annex_auto_get = true } })
    git_init(dir .. "/data")
    run({ "git", "annex", "init", "test" }, dir .. "/data")
    ok(attach_git.use_annex(dir .. "/data"))
    buf = file_buffer(dir, { "* Task", ":PROPERTIES:", ":ID: abcdef", ":END:" })
    utils.writefile(dir .. "/small.txt", { "x" })
    utils.writefile(dir .. "/big.txt", { string.rep("x", 100) })
    attach.attach_file(dir .. "/small.txt", "cp", { bufnr = buf, lnum = 1 })
    attach.attach_file(dir .. "/big.txt", "cp", { bufnr = buf, lnum = 1 })
    eq("link", vim.uv.fs_lstat(dir .. "/data/ab/cdef/big.txt").type)
    eq("file", vim.uv.fs_lstat(dir .. "/data/ab/cdef/small.txt").type)
    attach_git.annex_get_maybe(dir .. "/data/ab/cdef/big.txt", dir .. "/data")
  end)
end)
