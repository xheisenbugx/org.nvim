---@mod org.babel.lang.csharp C# blocks (ob-csharp)
---
--- Each block becomes a .NET project in a temporary directory that is
--- restored, built with `dotnet build` and run.

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

--- `%S` of a string.
local function q(s)
  return lisp.prin1(s)
end

--- `org-babel-csharp--default-compile-command`
function M.default_compile_command(dir_proj_sln, bin_dir)
  local o = ob.opts("csharp") or {}
  return string.format("%s build --output %s %s", o.compiler or "dotnet", q(bin_dir), q(dir_proj_sln))
end

--- `org-babel-csharp--default-restore-command`
function M.default_restore_command(project_file)
  local o = ob.opts("csharp") or {}
  return string.format("%s restore %s", o.compiler or "dotnet", q(project_file))
end

--- `org-babel-csharp--find-dotnet-version`: the major versions of the
--- installed SDKs.
function M.dotnet_versions()
  local o = ob.opts("csharp") or {}
  local ok, res = pcall(function()
    return vim.system({ "sh", "-c", (o.compiler or "dotnet") .. " --list-sdks" }, { text = true }):wait()
  end)
  local out = {}
  if not ok or not res.stdout then
    return out
  end
  local seen = {}
  for _, l in ipairs(vim.split(res.stdout, "\n")) do
    local n = tonumber(l:match("^(%d+)%.[%d.]*") or "")
    if n and n ~= 0 and not seen[n] then
      seen[n] = true
      out[#out + 1] = n
    end
  end
  return out
end

--- `org-babel-csharp-default-target-framework`: "netN.0" for the newest SDK.
function M.default_framework()
  local o = ob.opts("csharp") or {}
  if o.default_target_framework then
    return o.default_target_framework
  end
  local v = M.dotnet_versions()
  table.sort(v)
  return string.format("net%s.0", v[#v] and tostring(v[#v]) or "nil")
end

--- References of `:references`: strings, or ("name" . "version") pairs.
local function parse_refs(v)
  local s = ob.unq(v)
  if not s then
    return nil
  end
  local refs = {}
  local body = s:match("^%s*'?%((.*)%)%s*$") or s
  local i = 1
  while i <= #body do
    local name, ver, e = body:match('^%s*%(%s*"([^"]*)"%s*%.%s*"([^"]*)"%s*%)()', i)
    if name then
      refs[#refs + 1] = { name, ver }
      i = e
    else
      local str
      str, e = body:match('^%s*"([^"]*)"()', i)
      if not str then
        break
      end
      refs[#refs + 1] = str
      i = e
    end
  end
  return #refs > 0 and refs or nil
end

--- `org-babel-csharp--format-refs`
local function format_refs(refs, cwd)
  local project, assembly, system = nil, nil, nil
  for _, ref in ipairs(refs) do
    local version = type(ref) == "table" and ref[2] or nil
    local name = type(ref) == "table" and ref[1] or ref
    local full = vim.fn.resolve(vim.fn.fnamemodify(cwd .. "/" .. name, ":p"))
    if name:match("^/") then
      full = vim.fn.resolve(name)
    end
    local ext = full:match("%.([^./]+)$")
    if ext == "csproj" then
      project = (project or "") .. string.format('\n    <ProjectReference Include="%s" />', full)
    elseif ext == "dll" then
      assembly = (assembly or "")
        .. string.format(
          "\n    <Reference Include=%s>\n      <HintPath>%s</HintPath>\n    </Reference>",
          q(vim.fn.fnamemodify(full, ":t:r")),
          full
        )
    else
      system = (system or "")
        .. string.format(
          "\n    <PackageReference Include=%s />",
          version and (q(name) .. " Version=" .. q(version)) or q(name)
        )
    end
  end
  local function group(x)
    return x and ("<ItemGroup>" .. x .. "\n  </ItemGroup>") or ""
  end
  return string.format("%s\n\n  %s\n\n  %s", group(project), group(assembly), group(system))
end

--- `org-babel-csharp--generate-project-file`
function M.project_file(refs, framework, cwd)
  local o = ob.opts("csharp") or {}
  return "<Project Sdk=\"Microsoft.NET.Sdk\">\n\n  "
    .. (refs and format_refs(refs, cwd) or "")
    .. "\n\n  <PropertyGroup>"
    .. "\n    <OutputType>Exe</OutputType>\n"
    .. string.format("\n    <TargetFramework>%s</TargetFramework>", framework)
    .. "\n    <ImplicitUsings>enable</ImplicitUsings>"
    .. "\n    <Nullable>enable</Nullable>"
    .. (o.additional_project_flags and ("\n    " .. o.additional_project_flags) or "")
    .. "\n  </PropertyGroup>"
    .. "\n</Project>"
end

--- `org-babel-expand-body:csharp`
function M.expand(body, args, vars)
  local main_p = ob.unq(args.main) ~= "no"
  local class = ob.unq(args.class)
  if class == "no" then
    class = nil
  elseif class == nil then
    class = "Program"
  end
  local out = {}
  if args.prologue then
    out[#out + 1] = ob.unq(args.prologue) .. "\n"
  end
  out[#out + 1] = "namespace org.babel.autogen;\n"
  local usings = ob.list_or_string(args.usings)
  if usings then
    if type(usings) ~= "table" then
      error("Usings must be of type string.", 0)
    end
    local u = {}
    for i, x in ipairs(usings) do
      if type(x) ~= "string" then
        error("Usings must be of type string.", 0)
      end
      u[i] = "using " .. x .. ";"
    end
    out[#out + 1] = "\n" .. table.concat(u, "\n") .. "\n"
  end
  if class then
    out[#out + 1] = "\nclass " .. class .. "\n{\n"
  end
  if main_p then
    out[#out + 1] = "static void Main(string[] args)\n{\n"
  end
  local vl = {}
  for i, v in ipairs(vars) do
    vl[i] = string.format("var %s = %s;", v.name, lisp.prin1(v.value))
  end
  out[#out + 1] = table.concat(vl, "\n") .. "\n"
  out[#out + 1] = ob.body_text(body)
  if main_p then
    out[#out + 1] = "\n}"
  end
  if class then
    out[#out + 1] = "\n}"
  end
  if args.epilogue then
    out[#out + 1] = "\n" .. ob.unq(args.epilogue)
  end
  return table.concat(out)
end

function M.prepare(body, args, vars, ctx)
  local o = ctx.opts
  local full = M.expand(body, args, vars)
  local base = vim.fn.fnamemodify(vim.fn.tempname(), ":h") .. "/obcs" .. string.format("%d", vim.uv.hrtime()):sub(-8)
  local name = vim.fn.fnamemodify(base, ":t")
  local bin = base .. "/bin"
  local framework = ob.unq(args.framework) or M.default_framework()
  if #M.dotnet_versions() == 0 then
    error("Could not find a .NET SDK for compiling.", 0)
  end
  vim.fn.mkdir(base, "p")
  local project = base .. "/" .. name .. ".csproj"
  ob.write(base .. "/Program.cs", full)
  ob.write(project, M.project_file(parse_refs(args.references), framework, ctx.cwd))
  local nuget = ob.unq(args.nugetconfig)
  if nuget then
    local src = vim.fn.fnamemodify(ctx.cwd .. "/" .. nuget, ":p")
    if nuget:match("^/") then
      src = nuget
    end
    if vim.fn.filereadable(src) == 1 then
      vim.uv.fs_copyfile(src, base .. "/" .. vim.fn.fnamemodify(src, ":t"))
    end
  end
  local restore = (o.generate_restore_command or M.default_restore_command)(project)
  local compile_fn = o.generate_compile_command or M.default_compile_command
  local compile = compile_fn(vim.fn.resolve(project), vim.fn.resolve(bin))
  local run = string.format("%s %s", q(vim.fn.resolve(bin) .. "/" .. name), q(ob.unq(args.cmdline) or ""))
  return {
    steps = {
      { cmd = restore },
      {
        cmd = compile,
        after = function(res)
          local out = res.stdout or ""
          if out:find(": error", 1, true) then
            require("org.babel").error_notify(1, out)
          end
        end,
      },
      { cmd = run },
    },
    convert = function(raw)
      if raw == nil then
        return nil
      end
      local results = ob.remove_indentation(raw)
      return ob.result_cond(args, results, function(s)
        return ob.import(s)
      end)
    end,
  }
end

return M
