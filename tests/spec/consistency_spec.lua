-- Cross-checks between the action registry, the default mappings, the
-- menus, the option defaults and their LuaLS types in lua/org/_meta/.
local config = require("org.config")
local actions = require("org.actions")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local defaults = config.defaults
local maps = defaults.mappings
local ACTION_SECTIONS = { "global", "org", "org_insert", "emacs_global", "emacs", "emacs_insert" }

--- Classes of lua/org/_meta/*.lua: { [class] = { fields = { [name] = { type, doc } }, parent } }
local function meta_classes()
  local classes = {}
  for _, f in ipairs(vim.fn.glob(root .. "/lua/org/_meta/*.lua", false, true)) do
    local cur, doc = nil, {}
    for _, line in ipairs(vim.fn.readfile(f)) do
      local cls, parent = line:match("^%-%-%-@class%s+([%w%._]+)%s*:?%s*([%w%._]*)")
      if cls then
        cur = cls
        classes[cls] = classes[cls] or { fields = {} }
        if parent ~= "" then
          classes[cls].parent = parent
        end
        doc = {}
      else
        local name, ty = line:match("^%-%-%-@field%s+([%w_]+)%??%s+(.*)$")
        if name and cur then
          classes[cur].fields[name] = { type = ty, doc = table.concat(doc, " ") }
          doc = {}
        elseif line:match("^%-%-%-") then
          doc[#doc + 1] = line:sub(4)
        else
          cur, doc = nil, {}
        end
      end
    end
  end
  return classes
end

local function meta_field(classes, cls, name)
  while cls and classes[cls] do
    local f = classes[cls].fields[name]
    if f then
      return f
    end
    cls = classes[cls].parent
  end
end

local function keycode(lhs)
  return vim.keycode((lhs:gsub("<[lL]eader>", vim.g.mapleader or "\\")))
end

--- Same-mode default keys of `sections` that are equal (for different
--- actions) or a prefix of each other (Vim then waits 'timeoutlen').
local function conflicts(sections, mode_of)
  local by_mode, out = {}, {}
  for _, sec in ipairs(sections) do
    for name, value in pairs(maps[sec] or {}) do
      for _, lhs in ipairs(config.lhs_list(value)) do
        for _, mode in ipairs(mode_of(sec, name)) do
          by_mode[mode] = by_mode[mode] or {}
          table.insert(by_mode[mode], { key = keycode(lhs), lhs = lhs, name = name, sec = sec })
        end
      end
    end
  end
  for mode, list in pairs(by_mode) do
    for i, a in ipairs(list) do
      for j, b in ipairs(list) do
        if i ~= j and a.name ~= b.name then
          if a.key == b.key and i < j then
            out[#out + 1] = string.format("[%s] %s: %s.%s and %s.%s", mode, a.lhs, a.sec, a.name, b.sec, b.name)
          elseif #a.key < #b.key and b.key:sub(1, #a.key) == a.key then
            out[#out + 1] = string.format(
              "[%s] %s (%s.%s) is a prefix of %s (%s.%s)",
              mode,
              a.lhs,
              a.sec,
              a.name,
              b.lhs,
              b.sec,
              b.name
            )
          end
        end
      end
    end
  end
  table.sort(out)
  return out
end

describe("consistency", function()
  it("binds only registered actions in the action sections", function()
    local missing = {}
    for _, sec in ipairs(ACTION_SECTIONS) do
      for name in pairs(maps[sec] or {}) do
        if not actions.list[name] then
          missing[#missing + 1] = sec .. "." .. name
        end
      end
    end
    eq({}, missing)
  end)

  it("binds only agenda actions in mappings.agenda", function()
    local view = require("org.agenda.view")
    local missing = {}
    for name in pairs(maps.agenda) do
      if not view.actions[name] then
        missing[#missing + 1] = name
      end
    end
    eq({}, missing)
  end)

  it("points every action at an existing function", function()
    local broken = {}
    for name, a in pairs(actions.list) do
      local ok, mod = pcall(require, a[1])
      if not ok or type(mod[a[2]]) ~= "function" then
        broken[#broken + 1] = string.format("%s -> %s.%s", name, a[1], a[2])
      end
    end
    table.sort(broken)
    eq({}, broken)
  end)

  it("names only registered actions in the menus", function()
    local view = require("org.agenda.view")
    local unknown = {}
    for _, f in ipairs({ "lua/org/menu_defs.lua", "lua/org/menu.lua" }) do
      local src = table.concat(vim.fn.readfile(root .. "/" .. f), "\n")
      for _, pat in ipairs({ '[^%w_]action = "([%w_]+)"', 'key_or_nil%("([%w_]+)"', 'actions"%)%.run%("([%w_]+)"' }) do
        for name in src:gmatch(pat) do
          if not actions.list[name] then
            unknown[#unknown + 1] = f .. ": " .. name
          end
        end
      end
      for name in src:gmatch('[^%w_]agenda = "([%w_]+)"') do
        if not view.actions[name] then
          unknown[#unknown + 1] = f .. ": agenda " .. name
        end
      end
    end
    eq({}, unknown)
  end)

  it("lists every action in the org.ActionName alias and nothing else", function()
    local alias, inside = {}, false
    for _, line in ipairs(vim.fn.readfile(root .. "/lua/org/_meta/mappings.lua")) do
      if line:match("^%-%-%-@alias org%.ActionName") then
        inside = true
      elseif inside then
        local name = line:match('^%-%-%-|%s*"([%w_]+)"')
        if not name then
          break
        end
        alias[name] = true
      end
    end
    local missing, extra = {}, {}
    for name in pairs(actions.list) do
      if not alias[name] then
        missing[#missing + 1] = name
      end
    end
    for name in pairs(alias) do
      if not actions.list[name] then
        extra[#extra + 1] = name
      end
    end
    table.sort(missing)
    table.sort(extra)
    eq({ missing = {}, extra = {} }, { missing = missing, extra = extra })
  end)

  it("has no duplicate or prefix default keys in org buffers", function()
    local function modes(sec, name)
      if sec == "org_insert" or sec == "emacs_insert" then
        return { "i" }
      end
      local out = {}
      for _, m in ipairs(actions.list[name].modes or { "n" }) do
        -- `org` maps insert mode only for meta_return / meta_shift_return
        if m ~= "i" then
          out[#out + 1] = m
        end
      end
      return out
    end
    eq({}, conflicts({ "org", "emacs", "org_insert", "emacs_insert" }, modes))
  end)

  it("has no duplicate or prefix default keys in the agenda", function()
    eq(
      {},
      conflicts({ "agenda" }, function()
        return { "n" }
      end)
    )
  end)

  it("types every option in lua/org/_meta/", function()
    local classes = meta_classes()
    local missing = {}
    local function walk(tbl, cls, path)
      for k, v in pairs(tbl) do
        if type(k) == "string" then
          local f = meta_field(classes, cls, k)
          if not f then
            missing[#missing + 1] = path .. k
          elseif type(v) == "table" and not vim.islist(v) then
            local sub = f.type:match("^(org%.Config[%w%._]*)")
            if sub and classes[sub] then
              walk(v, sub, path .. k .. ".")
            end
          end
        end
      end
    end
    walk(defaults, "org.Config", "")
    table.sort(missing)
    eq({}, missing)
  end)

  it("gives the real default in the (default: `...`) of the option types", function()
    local classes = meta_classes()
    -- one class shared by options whose defaults differ
    local shared = { ["babel.default_inline_header_args"] = true, ["babel.default_lob_header_args"] = true }
    local wrong = {}
    local function walk(tbl, cls, path)
      for k, v in pairs(tbl) do
        local f = type(k) == "string" and meta_field(classes, cls, k)
        if f and not shared[path .. k] then
          local d = f.doc:match("default:?%s*`([^`]*)`")
          local chunk = d and d ~= "" and not d:find("...", 1, true) and load("return " .. d)
          if chunk then
            local ok, val = pcall(chunk)
            if ok and val ~= nil and not vim.deep_equal(val, v) then
              wrong[#wrong + 1] = string.format("%s%s: %s, actually %s", path, k, d, vim.inspect(v))
            end
          end
          if type(v) == "table" and not vim.islist(v) then
            local sub = f.type:match("^(org%.Config[%w%._]*)")
            if sub and classes[sub] then
              walk(v, sub, path .. k .. ".")
            end
          end
        end
      end
    end
    walk(defaults, "org.Config", "")
    table.sort(wrong)
    eq({}, wrong)
  end)
end)
