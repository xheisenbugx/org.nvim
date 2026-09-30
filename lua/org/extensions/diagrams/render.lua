---@mod org.extensions.diagrams.render Babel handlers of the diagrams extension
---
--- Handlers in the `org.babel.ob` form for `mermaid` (ob-mermaid, mmdc),
--- `dot` (ob-dot, Graphviz) and a wrapper around the core `plantuml` port.
--- Each one writes the diagram to the block's `:file` (or a generated name
--- under `output_dir`) and keeps a copy in `cache_dir` keyed by a hash of
--- the language, the command and the expanded body, so an unchanged
--- diagram is copied instead of rendered again.

local ob = require("org.babel.ob")

local M = {}

local function opts()
  return require("org.extensions").opts("diagrams") or require("org.extensions.diagrams").defaults
end

---------------------------------------------------------------------------
-- Commands and tools
---------------------------------------------------------------------------

--- The command of a tool option as a shell fragment: a list is quoted word
--- by word, a string is used as it is (so `"npx -y @mermaid-js/mermaid-cli"`
--- works), with `~` expanded.
function M.command_string(cmd)
  if type(cmd) == "table" then
    local parts = {}
    for i, w in ipairs(cmd) do
      parts[i] = ob.sh(require("org.utils").expand(w))
    end
    return table.concat(parts, " ")
  end
  return require("org.utils").expand(cmd or "")
end

--- The program a tool option runs (its first word), for `executable()`.
function M.program(cmd)
  if type(cmd) == "table" then
    return require("org.utils").expand(cmd[1] or "")
  end
  return require("org.utils").expand((cmd or ""):match("^%s*(%S+)") or "")
end

--- Whether the program of `cmd` is installed.
function M.available(cmd)
  local p = M.program(cmd)
  return p ~= "" and vim.fn.executable(p) == 1
end

local function extra_args(list)
  local out = {}
  for _, a in ipairs(list or {}) do
    out[#out + 1] = ob.sh(a)
  end
  return #out > 0 and (" " .. table.concat(out, " ")) or ""
end

---------------------------------------------------------------------------
-- Output file and cache
---------------------------------------------------------------------------

--- The content hash of a diagram: language, command shape and body.
function M.hash(lang, shape, ext, text)
  return vim.fn.sha256(table.concat({ lang, shape, ext or "", text }, "\0"))
end

--- Path of the cached output for `hash` and `ext`.
function M.cache_path(hash, ext)
  local dir = opts().cache_dir
  return require("org.utils").expand(dir) .. "/" .. hash .. (ext and ext ~= "" and ("." .. ext) or "")
end

local function copy(from, to)
  local data = ob.read(from)
  if not data then
    error("diagrams: can't read " .. from, 0)
  end
  vim.fn.mkdir(vim.fn.fnamemodify(to, ":h"), "p")
  ob.write(to, data)
end

--- The block's output file (as written in the link) and its absolute path.
--- A block without `:file` whose result is a file gets
--- `output_dir/LANG-HASH8.EXT` (HASH8: the start of the content hash), and
--- `args.file` is set so the result is a link to it.
---@return string|nil file, string|nil abs, string ext
function M.output_file(lang, args, ctx, text)
  local o = opts()
  local file = ob.unq(args.file)
  local ext
  if file and file ~= "" then
    ext = file:match("%.([^./]+)$") or ""
  else
    if not ob.rp(args).file or not o.auto_file then
      return nil, nil, ""
    end
    ext = ob.unq(args["file-ext"]) or o.format or "png"
    local name = lang .. "-" .. M.hash(lang, "", ext, text):sub(1, 8)
    local dir = o.output_dir or ""
    file = (dir ~= "" and (dir:gsub("/+$", "") .. "/") or "") .. name .. "." .. ext
    args.file = file
  end
  local abs = require("org.utils").expand(file, ctx.cwd)
  if not abs:match("^/") then
    abs = (ctx.cwd or vim.fn.getcwd()) .. "/" .. abs
  end
  return file, abs, ext
end

--- Wrap a spec with the cache: on a hit the cached file is copied to
--- `abs` and nothing runs; on a miss a last step stores the output.
local function cached(spec_fn, hash, ext, abs)
  local o = opts()
  -- set by diagrams_rerender for one run
  local skip = M.skip_cache
  M.skip_cache = nil
  if o.cache and abs and not skip then
    local c = M.cache_path(hash, ext)
    if vim.fn.filereadable(c) == 1 then
      copy(c, abs)
      M.last = { hit = true, hash = hash, file = abs }
      return { steps = {} }
    end
  end
  if abs then
    vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
  end
  local spec = spec_fn()
  M.last = { hit = false, hash = hash, file = abs }
  if o.cache and abs then
    spec.steps[#spec.steps + 1] = {
      fn = function()
        if vim.fn.filereadable(abs) == 1 and vim.fn.getfsize(abs) > 0 then
          copy(abs, M.cache_path(hash, ext))
        end
        return ""
      end,
    }
  end
  return spec
end

---------------------------------------------------------------------------
-- mermaid (ob-mermaid)
---------------------------------------------------------------------------

M.mermaid = {}

function M.mermaid.expand(body)
  return ob.body_text(body)
end

--- org-babel-execute:mermaid: `mmdc -i IN -o OUT` with :theme,
--- :background-color, :width, :height, :mermaid-config-file, :css-file,
--- :pupeteer-config-file (sic) / :puppeteer-config-file and :scale.
function M.mermaid.prepare(body, args, _, ctx)
  local o = opts()
  local mo = o.mermaid or {}
  local text = M.mermaid.expand(body)
  local file, abs, ext = M.output_file("mermaid", args, ctx, text)
  if not file then
    error('mermaid requires a ":file" header argument', 0)
  end
  if not M.available(mo.command) then
    error("diagrams: mermaid needs mmdc (`extensions.diagrams.mermaid.command`: " .. M.program(mo.command) .. ")", 0)
  end
  local function opt(flag, v, path)
    v = ob.unq(v)
    if v == nil or v == "" then
      return ""
    end
    if path then
      v = require("org.utils").expand(v, ctx.cwd)
    end
    return " " .. flag .. " " .. ob.sh(v)
  end
  local theme = args.theme or mo.theme
  local bg = args["background-color"] or mo.background
  local flags = opt("-t", theme)
    .. opt("-b", bg)
    .. opt("-w", args.width)
    .. opt("-H", args.height)
    .. opt("-c", args["mermaid-config-file"] or mo.config_file, true)
    .. opt("-C", args["css-file"], true)
    .. opt("-p", args["pupeteer-config-file"] or args["puppeteer-config-file"] or mo.puppeteer_config, true)
    .. opt("-s", args.scale)
    .. extra_args(mo.args)
  local shape = M.command_string(mo.command) .. flags
  return cached(function()
    local in_file = ob.temp(".mmd")
    ob.write(in_file, text)
    local cmd = M.command_string(mo.command) .. " -i " .. ob.sh(in_file) .. " -o " .. ob.sh(abs) .. flags
    return {
      steps = { { cmd = cmd } },
      convert = function()
        return nil
      end,
    }
  end, M.hash("mermaid", shape, ext, text), ext, abs)
end

---------------------------------------------------------------------------
-- dot (ob-dot)
---------------------------------------------------------------------------

M.dot = {}

--- org-babel-expand-body:dot: `$NAME` becomes the value of :var NAME.
function M.dot.expand(body, _, vars)
  local text = ob.body_text(body)
  for _, v in ipairs(vars or {}) do
    local val = type(v.value) == "string" and v.value or require("org.babel.lisp").prin1(v.value)
    text = text:gsub("%$" .. vim.pesc(v.name), function()
      return val
    end)
  end
  return text
end

--- org-babel-execute:dot: `CMD IN CMDLINE -o OUT`, CMDLINE defaulting to
--- `-T` plus the output extension, CMD to `dot` (:cmd, or the `dot.command`
--- option).
function M.dot.prepare(body, args, vars, ctx)
  local o = opts()
  local dop = o.dot or {}
  local text = M.dot.expand(body, args, vars)
  local file, abs, ext = M.output_file("dot", args, ctx, text)
  if not file then
    error("You need to specify a :file parameter", 0)
  end
  local cmd = ob.unq(args.cmd)
  local prog = cmd or dop.command
  if not M.available(prog) then
    error("diagrams: dot needs Graphviz (`extensions.diagrams.dot.command`: " .. M.program(prog) .. ")", 0)
  end
  local cmdline = ob.unq(args.cmdline) or ("-T" .. ext)
  local base = cmd or M.command_string(dop.command)
  local tail = " " .. cmdline .. extra_args(dop.args)
  return cached(function()
    local in_file = ob.temp(".dot")
    ob.write(in_file, text)
    return {
      steps = { { cmd = base .. " " .. ob.sh(in_file) .. tail .. " -o " .. ob.sh(abs) } },
      convert = function()
        return nil
      end,
    }
  end, M.hash("dot", base .. tail, ext, text), ext, abs)
end

---------------------------------------------------------------------------
-- plantuml (the core port, with the cache and generated file names)
---------------------------------------------------------------------------

M.plantuml = {}

function M.plantuml.expand(body, args, vars)
  return require("org.babel.lang.plantuml").expand(body, args, vars)
end

--- The core `plantuml` handler, plus: a generated `:file`, the cache, and
--- the `plantuml` executable when no jar is configured.
function M.plantuml.prepare(body, args, vars, ctx)
  local core = require("org.babel.lang.plantuml")
  local po = ctx.opts or {}
  if (po.exec_mode or "jar") == "jar" and (po.jar_path or "") == "" then
    local exe = po.executable_path or "plantuml"
    if vim.fn.executable(exe) == 1 then
      ctx.opts = vim.tbl_extend("force", po, { exec_mode = "plantuml" })
    end
  end
  local text = core.make_body(body, args, vars)
  local file, abs, ext = M.output_file("plantuml", args, ctx, text)
  if not file then
    -- text output (:results verbatim ...): as in the core port, not cached
    return core.prepare(body, args, vars, ctx)
  end
  local o = ctx.opts
  local shape = table.concat({
    o.exec_mode or "jar",
    o.executable_path or "",
    o.jar_path or "",
    table.concat(o.args or {}, " "),
    ob.unq(args.cmdline) or "",
    ob.unq(args.java) or "",
  }, "\1")
  return cached(function()
    return core.prepare(body, args, vars, ctx)
  end, M.hash("plantuml", shape, ext, text), ext, abs)
end

return M
