-- Asynchronous compiles (LaTeX -> PDF, Texinfo -> Info, man -> PDF) run
-- their process one command at a time. Each next command used to start
-- from the previous one's exit callback, a fast event where reading
-- 'shell' raises E5560, so a process of more than one command (the
-- default 3 x %latex without latexmk) never finished.

local config = require("org.config")

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return require("org.utils").realpath(d)
end

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

-- run compile(file, on_done) and wait for on_done
local function compile_async(compile, file)
  local res
  compile(file, function(...)
    res = { ... }
  end)
  -- (three processes one after another: sh.exe on a busy Windows runner
  -- took over 5 seconds for them)
  vim.wait(30000, function()
    return res ~= nil
  end, 10)
  return res
end

local cases = {
  {
    name = "latex",
    area = "latex",
    key = "pdf_process",
    ext = "tex",
    out = "pdf",
    -- three steps like the default without latexmk; the last one makes the PDF
    process = { "true", "touch %b.step2", "cp %f %b.pdf" },
  },
  {
    name = "texinfo",
    area = "texinfo",
    key = "info_process",
    ext = "texi",
    out = "info",
    process = { "true", "touch %b.step2", "cp %f %b.info" },
  },
  {
    name = "man",
    area = "man",
    key = "pdf_process",
    ext = "man",
    out = "pdf",
    process = { "true", "touch %b.step2", "cp %f %b.pdf" },
  },
}

describe("asynchronous compile with a multi-command process", function()
  -- the processes are POSIX commands (sh from Git for Windows on Windows)
  posix_shell()
  for _, c in ipairs(cases) do
    it("runs every " .. c.name .. " command and calls on_done", function()
      local saved = config.opts.export[c.area]
      config.opts.export[c.area] = vim.tbl_extend("force", saved or {}, { [c.key] = c.process })
      local d = tmpdir()
      local src = d .. "/doc." .. c.ext
      vim.fn.writefile({ "x" }, src)
      local errmsg = vim.v.errmsg
      local ok_, res = pcall(compile_async, require("org.export." .. c.name).compile, src)
      config.opts.export[c.area] = saved
      ok(ok_, res)
      ok(res, "on_done was never called")
      eq(d .. "/doc." .. c.out, res[1])
      eq(nil, res[2])
      eq(1, vim.fn.filereadable(d .. "/doc.step2"))
      eq(read(src), read(res[1]))
      eq(errmsg, vim.v.errmsg)
    end)
  end
end)
