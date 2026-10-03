---@mod org.babel.lang.groovy Groovy blocks (ob-groovy)
---
--- Like Emacs, `:var` is not supported (the body is expanded without
--- assignments) and there are no sessions.

local ob = require("org.babel.ob")

local M = {}

M.WRAPPER = [[class Runner extends Script {
    def out = new PrintWriter(new ByteArrayOutputStream())
    def run() { %s }
}

println(new Runner().run())
]]

function M.expand(body, args)
  return ob.expand_generic(type(body) == "table" and body or { body }, args, {})
end

function M.prepare(body, args, vars, ctx)
  local full = M.expand(body, args)
  local value = args.results_spec.collection == "value"
  local src = ob.temp()
  ob.write(src, value and (M.WRAPPER:gsub("%%s", function()
    return full
  end)) or full)
  return {
    steps = { { cmd = (ctx.opts.cmd or "groovy") .. " " .. src } },
    convert = function(raw)
      if not value then
        return raw
      end
      return ob.result_cond(args, raw, function(s)
        return require("org.babel.lisp").script_escape(s)
      end)
    end,
  }
end

return M
