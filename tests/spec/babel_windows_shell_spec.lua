-- Babel where `sh` isn't on $PATH (Windows without Git's sh, #328): shell
-- command lines go through 'shell' and 'shellcmdflag', the C# SDK root is
-- found in a Windows path, and the temporary file names written into
-- Python and Lua scripts have no backslashes for the language to read as
-- escapes.
local blocks = require("org.babel.blocks")
local ob = require("org.babel.ob")

describe("babel without sh", function()
  local saved = {}
  before_each(function()
    saved = {
      executable = vim.fn.executable,
      system = vim.system,
      tempname = vim.fn.tempname,
      shell = vim.o.shell,
      shellcmdflag = vim.o.shellcmdflag,
    }
  end)
  after_each(function()
    vim.fn.executable = saved.executable
    vim.system = saved.system
    vim.fn.tempname = saved.tempname
    vim.o.shell = saved.shell
    vim.o.shellcmdflag = saved.shellcmdflag
  end)

  local function no_sh()
    local executable = saved.executable
    vim.fn.executable = function(name)
      if name == "sh" then
        return 0
      end
      return executable(name)
    end
  end

  it("runs a command line with sh -c when sh is on the PATH", function()
    vim.fn.executable = function(name)
      return name == "sh" and 1 or 0
    end
    eq({ "sh", "-c", "dotnet --list-sdks" }, ob.shell_argv("dotnet --list-sdks"))
  end)

  it("runs a command line with 'shell' and 'shellcmdflag' without sh", function()
    no_sh()
    vim.o.shell = "cmd.exe"
    vim.o.shellcmdflag = "/s /c"
    eq({ "cmd.exe", "/s", "/c", "dotnet --list-sdks" }, ob.shell_argv("dotnet --list-sdks"))
    vim.o.shell = "pwsh"
    vim.o.shellcmdflag = "-NoLogo -Command"
    eq({ "pwsh", "-NoLogo", "-Command", "x" }, ob.shell_argv("x"))
  end)

  it("lists the .NET SDKs through the shell and finds a Windows SDK root", function()
    no_sh()
    vim.o.shell = "cmd.exe"
    vim.o.shellcmdflag = "/s /c"
    local argv
    vim.system = function(cmd)
      argv = cmd
      return {
        wait = function()
          return {
            code = 0,
            stdout = "8.0.100 [C:\\Program Files\\dotnet\\sdk]\r\n9.0.200 [C:\\Program Files\\dotnet\\sdk]\r\n",
          }
        end,
      }
    end
    local csharp = require("org.babel.lang.csharp")
    eq({ 8, 9 }, csharp.dotnet_versions())
    eq({ "cmd.exe", "/s", "/c", "dotnet --list-sdks" }, argv)
    eq("C:\\Program Files\\dotnet", csharp.dotnet_root())
  end)

  local function script_text(lang, header)
    local dir = vim.fn.tempname()
    -- `Users` too: on Windows the backslashes below are separators
    vim.fn.mkdir(dir .. "/Users", "p")
    local n = 0
    -- a temporary file name with a backslash, as tempname() gives on Windows
    vim.fn.tempname = function()
      n = n + 1
      return dir .. "\\Users\\t" .. n
    end
    local args = blocks.header_args({ params = header, header_lines = {}, start = 1, lang = lang }, nil)
    local langs = require("org.babel.langs")
    local cmd = langs.prepare(lang, { "1 + 1" }, args, {}, { cmd = { lang }, ext = lang == "python" and "py" or "lua" })
    local spec = cmd.steps[1]
    local code = spec.stdin or table.concat(vim.fn.readfile(spec.cmd[#spec.cmd]), "\n")
    return code, cmd.result_file
  end

  it("writes the result file name of a Python block with forward slashes", function()
    local code, result_file = script_text("python", ":results value")
    ok(result_file:find("\\", 1, true), "the file itself keeps its name")
    ok(code:find("'" .. result_file:gsub("\\", "/") .. "'", 1, true), code)
    ok(not code:find("\\Users", 1, true), code)
  end)

  it("writes the result file name of a Lua block with forward slashes", function()
    local code, result_file = script_text("lua", ":results value")
    ok(code:find(result_file:gsub("\\", "/"), 1, true), code)
    ok(not code:find("\\Users", 1, true), code)
  end)
end)
