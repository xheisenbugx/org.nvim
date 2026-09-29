---@mod org.babel.lang.clojure Clojure and ClojureScript blocks (ob-clojure)
---
--- The command-line backends of ob-clojure: babashka (`bb`), the Clojure
--- CLI (`clojure -M`) and nbb (ClojureScript). The cider, inf-clojure and
--- slime backends need Emacs packages and are not available.

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

local function exe(name)
  local p = vim.fn.exepath(name)
  return p ~= "" and p or nil
end

local function clj_opts()
  return ob.opts("clojure") or {}
end

--- `org-babel-clojure-backend` (default: babashka when `bb` is installed,
--- else clojure-cli when `clojure` is).
function M.backend()
  local b = clj_opts().backend
  if b then
    return b
  end
  if exe("bb") then
    return "babashka"
  elseif exe("clojure") then
    return "clojure-cli"
  end
  return nil
end

--- `org-babel-clojurescript-backend` (default: nbb when `nbb` or `npx` is
--- installed).
function M.cljs_backend()
  local b = (ob.opts("clojurescript") or {}).backend
  if b then
    return b
  end
  if exe("nbb") or exe("npx") then
    return "nbb"
  end
  return nil
end

--- The command of a backend (ob-clojure-babashka-command, ...).
function M.command(backend)
  local o = clj_opts()
  if backend == "babashka" then
    return o.babashka_command or exe("bb")
  elseif backend == "clojure-cli" then
    return o.cli_command or (exe("clojure") and (exe("clojure") .. " -M"))
  elseif backend == "nbb" then
    return o.nbb_command or exe("nbb") or (exe("npx") and (exe("npx") .. " nbb"))
  end
  return nil
end

local function no_backend_error()
  error("You need to customize `org-babel-clojure-backend'\nor set the `:backend' header argument", 0)
end

--- `org-babel-expand-body:clojure`
function M.clojure_expand(body, args, vars, cljs_p)
  if not (args.backend or M.backend()) then
    no_backend_error()
  end
  local ns = ob.unq(args.ns) or clj_opts().default_ns or "user"
  local text = ob.trim(ob.body_text(body))
  if #vars > 0 then
    -- comments would break the (let [...] ...) bindings
    local stripped = {}
    for _, l in ipairs(vim.split(ob.body_text(body), "\n", { plain = true })) do
      stripped[#stripped + 1] = l:match("^[ \t]*;+") and "" or l
    end
    local binds = {}
    for i, v in ipairs(vars) do
      binds[i] = string.format("%s '%s", v.name, lisp.prin1(v.value))
    end
    text = string.format("(let [%s]\n%s)", table.concat(binds, "\n      "), table.concat(stripped, "\n"))
  end
  text = ob.trim((args.ns and string.format("(ns %s)\n", ns) or "") .. text)
  local rp = ob.rp(args)
  if rp.output then
    return text
  end
  local head
  if rp.code or rp.pp then
    head = (cljs_p and "(require '[cljs.pprint :refer [pprint]])" or "(require '[clojure.pprint :refer [pprint]])")
      .. " (pprint "
  else
    head = "(prn "
  end
  return head
    .. (cljs_p and "(binding [cljs.core/*print-fn* (constantly nil)]" or "(binding [*out* (java.io.StringWriter.)]")
    .. text
    .. "))"
end

--- C-c C-v v: clojure blocks expand like org-babel-expand-body:clojure;
--- clojurescript has no expand function in Emacs (generic expansion).
function M.expand(body, args, vars, ectx)
  if ectx and ectx.lang == "clojurescript" then
    return ob.expand_generic(type(body) == "table" and body or { body }, args, {})
  end
  return M.clojure_expand(body, args, vars, false)
end

function M.prepare(body, args, vars, ctx)
  local cljs_p = ctx.lang == "clojurescript"
  local backend = ob.unq(args.backend)
  if not backend and M.backend() then
    -- ClojureScript uses its own backend, never the Clojure one
    if cljs_p then
      backend = M.cljs_backend()
    else
      backend = M.backend()
    end
  end
  if not backend then
    no_backend_error()
  end
  cljs_p = cljs_p or backend == "nbb"
  local expanded = M.clojure_expand(body, args, vars, cljs_p)
  local cmd = M.command(backend)
  if backend == "cider" or backend == "slime" or backend == "inf-clojure" then
    error("The " .. backend .. " backend needs Emacs; use babashka, clojure-cli or nbb", 0)
  elseif not ({ babashka = true, ["clojure-cli"] = true, nbb = true })[backend] then
    error("Invalid backend", 0)
  end
  if not cmd then
    error("No command for the " .. backend .. " backend", 0)
  end
  local script = ob.write(ob.temp(".clj"), expanded)
  return {
    steps = { { cmd = cmd .. " " .. ob.sh(script) } },
    convert = function(raw)
      return ob.result_cond(args, raw, function(s)
        local ok, v = pcall(lisp.script_escape, s)
        return ok and v or s
      end)
    end,
  }
end

return M
