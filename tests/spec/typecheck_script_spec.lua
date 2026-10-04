local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local typecheck = dofile(root .. "/scripts/typecheck.lua")

--- An LSP diagnostic as lua-language-server's JSON report has it.
local function diag(code, line, severity)
  return {
    code = code,
    message = code .. " here",
    severity = severity or 2,
    range = { start = { line = line - 1, character = 4 }, ["end"] = { line = line - 1, character = 8 } },
  }
end

--- "file:line:code" of every hit the filter keeps.
local function kept(report, strict)
  local uris = {}
  for file, diags in pairs(report) do
    uris[vim.uri_from_fname(root .. "/" .. file)] = diags
  end
  return vim.tbl_map(function(h)
    return h.file .. ":" .. h.line .. ":" .. h.code
  end, typecheck.filter(uris, root, { "need-check-nil", "undefined-field" }, strict))
end

describe("make typecheck (scripts/typecheck.lua)", function()
  it("takes the demoted diagnostics from .luarc.json", function()
    eq(
      { "need-check-nil", "undefined-field" },
      typecheck.demoted({
        ["diagnostics.severity"] = {
          ["need-check-nil"] = "Hint!",
          ["undefined-field"] = "Information",
          ["unused-local"] = "Warning",
          ["undefined-global"] = "Error!",
        },
      })
    )
    eq({}, typecheck.demoted({}))
  end)

  it("demotes the same set as the checked-in .luarc.json", function()
    local f = assert(io.open(root .. "/.luarc.json"))
    local luarc = vim.json.decode(f:read("*a"))
    f:close()
    ok(vim.tbl_contains(typecheck.demoted(luarc), "need-check-nil"))
    ok(vim.tbl_contains(typecheck.demoted(luarc), "param-type-mismatch"))
  end)

  it("reads the strict list: one path per line, comments and blanks skipped", function()
    eq(
      { "lua/org/api", "lua/org/parser.lua" },
      typecheck.parse_list("# header\n\nlua/org/api/  # a directory\n  lua/org/parser.lua\n")
    )
  end)

  it("lists only paths that exist", function()
    local f = assert(io.open(root .. "/scripts/typecheck_strict.txt"))
    local paths = typecheck.parse_list(f:read("*a"))
    f:close()
    ok(#paths > 0)
    for _, p in ipairs(paths) do
      ok(vim.uv.fs_stat(root .. "/" .. p), p)
    end
  end)

  it("matches a listed file, or anything under a listed directory", function()
    local strict = { "lua/org/api", "lua/org/parser.lua" }
    ok(typecheck.is_strict("lua/org/api/init.lua", strict))
    ok(typecheck.is_strict("lua/org/parser.lua", strict))
    ok(not typecheck.is_strict("lua/org/api_extra.lua", strict))
    ok(not typecheck.is_strict("lua/org/parser.lua.bak", strict))
    ok(not typecheck.is_strict("lua/org/files.lua", strict))
  end)

  it("reports demoted diagnostics only in strict files", function()
    eq(
      { "lua/a.lua:3:unused-local", "lua/s/b.lua:1:need-check-nil", "lua/s/b.lua:2:undefined-field" },
      kept({
        ["lua/a.lua"] = { diag("need-check-nil", 5), diag("unused-local", 3) },
        ["lua/s/b.lua"] = { diag("undefined-field", 2), diag("need-check-nil", 1) },
      }, { "lua/s" })
    )
  end)

  it("ignores information and hints everywhere", function()
    eq({}, kept({ ["lua/s/b.lua"] = { diag("need-check-nil", 1, 3), diag("unused-local", 2, 4) } }, { "lua/s" }))
  end)
end)
