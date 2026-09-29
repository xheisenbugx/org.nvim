---@mod org.babel.lang.java Java blocks (ob-java)
---
--- The body is wrapped in a class and a main method when it has none, like
--- `org-babel-expand-body:java`; blocks are compiled with javac and run
--- with java. The code is edited like Emacs edits a buffer (regexp
--- searches that ignore case, point moved past matches), so the result is
--- the same text.

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

-- rx `line-start`, `space`: a line start, whitespace including newlines
local BOL = [[%(^|\n)\zs]]
local S = [[\_s]]

--- A very magic, case-ignoring Vim regexp; `<BOL>` and `<S>` stand for
--- BOL and S.
local function rx(s)
  return "\\v\\c" .. s:gsub("<BOL>", function()
    return BOL
  end):gsub("<S>", function()
    return S
  end)
end

-- stylua: ignore
local RE = {
  package = rx([=[<BOL><S>*package<S>+([[:alnum:]_.]+)<S>*;\ze%(\n|$)]=]),
  imports = rx([=[<BOL><S>*import%(<S>+static)?<S>+([[:alnum:]_.*]+)<S>*;\ze%(\n|$)]=]),
  class = rx([=[<BOL><S>*%(public<S>+)?class<S>+([[:alnum:]_]+)<S>*\{]=]),
  main = rx([=[<BOL><S>*public<S>+static<S>+void<S>+main<S>*\(<S>*String%([[:alnum:]_[\]]|<S>)+\)]=]
    .. [=[<S>*%(throws%([[:alnum:]_,.]|<S>)+)?\{]=]),
  any_method = rx([=[<BOL><S>*%([[:alnum:]]+<S>+)?%(static<S>+)?[[:alnum:]_[\]]+<S>+[[:alnum:]_]+<S>*]=]
    .. [=[\(%([[:alnum:]_[\],]|<S>)*\)<S>*%(throws%([[:alnum:]_,.]|<S>)+)?\{]=]),
}
M.RE = RE

--- A text being edited with a point (1-based, like Emacs positions).
local Buf = {}
Buf.__index = Buf

local function buffer(text)
  return setmetatable({ text = text, pt = 1 }, Buf)
end

--- `re-search-forward`: move after the match, return its start, end and
--- groups (positions like Emacs: end is after the last character).
function Buf:search(re)
  local from = self.pt - 1
  local bol = re:find(BOL, 1, true) ~= nil
  while true do
    local m = vim.fn.matchstrpos(self.text, re, from)
    if m[2] < 0 then
      return nil
    end
    -- with a start offset `^` matches there: keep only real line starts
    if not (bol and m[2] == from and from > 0 and self.text:sub(from, from) ~= "\n") then
      local groups = vim.fn.matchlist(self.text, re, m[2])
      self.pt = m[3] + 1
      return m[2] + 1, m[3] + 1, groups
    end
    from = from + 1
  end
end

--- `org-babel-java--move-past`
function Buf:move_past(re)
  while true do
    local _, e = self:search(re)
    if not e then
      break
    end
    self.pt = math.min(e + 1, #self.text + 1)
  end
end

function Buf:insert(s)
  self.text = self.text:sub(1, self.pt - 1) .. s .. self.text:sub(self.pt)
  self.pt = self.pt + #s
end

--- `indent-code-rigidly` from point to the end by `n` columns (tabs for
--- each 8 columns, like `indent-tabs-mode`).
function Buf:indent_rigidly(n)
  local head = self.text:sub(1, self.pt - 1)
  local rest = self.text:sub(self.pt)
  -- lines starting in the region: the first one only when at its start
  local first_partial = self.pt > 1 and self.text:sub(self.pt - 1, self.pt - 1) ~= "\n"
  local lines = vim.split(rest, "\n", { plain = true })
  for i, l in ipairs(lines) do
    if not (i == 1 and first_partial) and l:match("%S") then
      local ws = l:match("^[ \t]*")
      local col = 0
      for c in ws:gmatch(".") do
        col = c == "\t" and (math.floor(col / 8) + 1) * 8 or col + 1
      end
      col = math.max(0, col + n)
      lines[i] = string.rep("\t", math.floor(col / 8)) .. string.rep(" ", col % 8) .. l:sub(#ws + 1)
    end
  end
  self.text = head .. table.concat(lines, "\n")
end

--- `org-babel-java-find-classname`
function M.find_classname(body)
  local b = buffer(body)
  local _, _, g = b:search(RE.package)
  local package = g and g[2]
  b.pt = 1
  _, _, g = b:search(RE.class)
  local class = g and g[2]
  if package and class then
    return package .. "." .. class
  end
  return class or (package and (package .. ".Main")) or "Main"
end

--- `org-babel-java-val-to-base-type`
local function base_type(v)
  if type(v) == "number" or lisp.is_bignum(v) then
    return "integerp"
  elseif lisp.is_float(v) then
    return "floatp"
  elseif lisp.is_list(v) then
    local t
    for _, x in ipairs(v) do
      local bt = base_type(x)
      if bt == "stringp" then
        t = "stringp"
      elseif bt == "floatp" then
        if not t or t == "integerp" then
          t = "floatp"
        end
      elseif bt == "integerp" then
        t = t or "integerp"
      end
    end
    return t
  end
  return "stringp"
end

--- `org-babel-java-var-to-java`
local function var_to_java(v, basetype)
  if lisp.is_list(v) then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = var_to_java(x, basetype)
    end
    return "Arrays.asList(" .. table.concat(parts, ", ") .. ")"
  elseif v == "hline" then
    return require("org.babel.langs").lang_opt("java", "hline_to", "null")
  elseif basetype == "integerp" then
    return string.format("%d", lisp.tonumber(v))
  elseif basetype == "floatp" then
    return string.format("%f", lisp.tonumber(v))
  end
  local s = lisp.princ(v)
  if s:find(".\n+.") then
    error("Java does not support multiline string literals", 0)
  end
  return '"' .. s .. '"'
end

--- `org-babel-variable-assignments:java`
local function var_lines(vars)
  local out = {}
  for _, v in ipairs(vars) do
    local basetype = base_type(v.value)
    local name = ({ integerp = "Integer", floatp = "Double", stringp = "String" })[basetype]
    if not name then
      error("Unknown type " .. tostring(basetype), 0)
    end
    local t = name
    if lisp.is_list(v.value) and lisp.is_list(v.value[1]) then
      t = "List<List<" .. name .. ">>"
    elseif lisp.is_list(v.value) then
      t = "List<" .. name .. ">"
    end
    out[#out + 1] = string.format("    static %s %s = %s;", t, v.name, var_to_java(v.value, basetype))
  end
  return out
end

local function split_classname(full)
  local classname = full:match("([^.]*)$")
  local package = full:find(".", 1, true) and full:match("^(.*)%.[^.]*$") or nil
  return classname, package
end

--- `org-babel-expand-body:java`
function M.expand(body, args, vars)
  local text = ob.body_text(body)
  local full = ob.unq(args.classname) or M.find_classname(text)
  local classname, packagename = split_classname(full)
  local vl = var_lines(vars)
  local imports = args.imports and vim.split(lisp.princ(ob.babel_read(ob.unq(args.imports))), " ", { plain = true })
    or nil
  local prologue, epilogue = ob.unq(args.prologue), ob.unq(args.epilogue)
  local b = buffer((prologue and (prologue .. "\n") or "") .. text .. (epilogue and ("\n" .. epilogue) or ""))
  -- wrap main
  if not b:search(RE.main) and not b:search(RE.any_method) then
    b:move_past(RE.package)
    b:move_past(RE.imports)
    b:insert("public static void main(String[] args) {\n")
    b:indent_rigidly(4)
    b.pt = #b.text + 1
    b:insert("\n}")
  end
  -- wrap class
  b.pt = 1
  if not b:search(RE.class) then
    b:move_past(RE.package)
    b:move_past(RE.imports)
    b:insert("\npublic class " .. classname .. " {\n")
    b:indent_rigidly(4)
    b.pt = #b.text + 1
    b:insert("\n}")
  end
  if #vl > 0 then
    b.pt = 1
    b:move_past(RE.class)
    b:insert(table.concat(vl, "\n"))
    b:insert("\n")
  end
  if imports then
    b.pt = 1
    b:move_past(RE.package)
    local il = {}
    for i, p in ipairs(imports) do
      il[i] = "import " .. p .. ";"
    end
    b:insert(table.concat(il, "\n") .. "\n")
  end
  b.pt = 1
  if packagename and not b:search(RE.package) then
    b.pt = 1
    b:insert("package " .. packagename .. ";\n")
  end
  return b.text
end

M.RESULT_WRAPPER = [[

    public static String __toString(Object val) {
        if (val instanceof String) {
            return "\"" + val + "\"";
        } else if (val == null) {
            return "null";
        } else if (val.getClass().isArray()) {
            StringBuffer sb = new StringBuffer();
            Object[] vals = (Object[])val;
            sb.append("[");
            for (int ii=0; ii<vals.length; ii++) {
                sb.append(__toString(vals[ii]));
                if (ii<vals.length-1)
                    sb.append(",");
            }
            sb.append("]");
            return sb.toString();
        } else if (val instanceof List) {
            StringBuffer sb = new StringBuffer();
            List vals = (List)val;
            sb.append("[");
            for (int ii=0; ii<vals.size(); ii++) {
                sb.append(__toString(vals.get(ii)));
                if (ii<vals.size()-1)
                    sb.append(",");
            }
            sb.append("]");
            return sb.toString();
        } else {
            return String.valueOf(val);
        }
    }

    public static void main(String[] args) throws IOException {
        BufferedWriter output = new BufferedWriter(new FileWriter("%s"));
        output.write(__toString(_main(args)));
        output.close();
    }]]

--- `org-babel-java--import-maybe`
local function import_maybe(b, package, class)
  b.pt = 1
  local found = b:search([[\c]] .. class)
  b.pt = 1
  local imported = b:search([[\c\v%(^|\n)\zsimport .*]] .. package .. [[.*%(\*|]] .. class .. [[);]])
  if found and not imported then
    b.pt = 1
    b:move_past(RE.package)
    b:insert("import " .. package .. "." .. class .. ";\n")
  end
end

--- `org-babel-java--expand-for-evaluation`
function M.expand_for_evaluation(body, suppress_package, value, result_file)
  local b = buffer(body)
  if suppress_package then
    local s, e = b:search(RE.package)
    if s then
      b.text = b.text:sub(1, s - 1) .. b.text:sub(e)
    end
  end
  b.pt = 1
  if not b:search(RE.main) then
    b:move_past(RE.class)
    b:insert('\n    public static void main(String[] args) {\n        System.out.print("success");\n    }\n\n')
  end
  if value then
    b.pt = 1
    b:move_past(RE.class)
    b:insert((M.RESULT_WRAPPER:gsub("%%s", (result_file:gsub("%%", "%%%%")))))
    local s, e = b:search([[\c\Vpublic static void main(]])
    if s then
      b.text = b.text:sub(1, s - 1) .. "public static Object _main(" .. b.text:sub(e)
    end
  end
  import_maybe(b, "java.util", "List")
  import_maybe(b, "java.util", "Arrays")
  import_maybe(b, "java.io", "BufferedWriter")
  import_maybe(b, "java.io", "FileWriter")
  import_maybe(b, "java.io", "IOException")
  return b.text
end

function M.prepare(body, args, vars, ctx)
  local o = ctx.opts
  local compiler = ob.unq(args.javac) or o.compiler or "javac"
  local java = ob.unq(args.java) or o.cmd or "java"
  local run_from_temp = args.dir == nil
  local text = ob.body_text(body)
  local full = ob.unq(args.classname) or M.find_classname(text)
  local classname, packagename = split_classname(full)
  local basedir = run_from_temp and vim.fn.fnamemodify(vim.fn.tempname(), ":h") or ctx.cwd
  basedir = basedir:sub(-1) == "/" and basedir or (basedir .. "/")
  local packagedir = basedir
  if not run_from_temp and packagename then
    packagedir = basedir .. packagename:gsub("%.", "/") .. "/"
  end
  local src = packagedir .. classname .. ".java"
  local value = args.results_spec.collection == "value"
  local result_file = value and ob.temp() or nil
  local cmd = compiler
    .. " "
    .. (ob.unq(args.cmpflag) or "")
    .. " "
    .. src
    .. " && "
    .. java
    .. " -cp "
    .. basedir
    .. " "
    .. (ob.unq(args.cmdline) or "")
    .. " "
    .. (run_from_temp and classname or full)
    .. " "
    .. (ob.unq(args.cmdargs) or "")
  vim.fn.mkdir(packagedir, "p")
  ob.write(src, M.expand_for_evaluation(M.expand(body, args, vars), run_from_temp, value, result_file))
  return {
    steps = { { cmd = cmd } },
    result_file = result_file,
    convert = function(raw)
      return ob.result_cond(args, raw, function(s)
        return ob.table_or_string(s, function(el)
          if lisp.is_symbol(el, "null") then
            local to = o.null_to
            if to == nil then
              to = "hline"
            end
            return (to == false or to == "nil") and {} or to
          end
        end)
      end)
    end,
  }
end

return M
