local function setup(opts)
  require("org").setup(vim.tbl_extend("force", {
    org_directory = vim.fn.getcwd() .. "/tests/fixtures",
    agenda_files = { vim.fn.getcwd() .. "/tests/fixtures/*.org" },
  }, opts or {}))
end

describe("extensions", function()
  local calls
  before_each(function()
    calls = {}
    package.loaded["org.extensions.testext"] = {
      defaults = { greeting = "hi", list = { 1, 2 }, nested = { a = 1, b = 2 } },
      actions = { testext_hello = { "org.extensions.testext", "hello", desc = "Say hello" } },
      commands = { testext_cmd = { "org.extensions.testext", "hello", desc = "Say hello with args" } },
      mappings = { global = { testext_hello = "<prefix>zz" } },
      setup = function(opts)
        calls[#calls + 1] = opts
      end,
      hello = function()
        calls.hello = true
      end,
    }
  end)
  after_each(function()
    package.loaded["org.extensions.testext"] = nil
    setup()
  end)

  it("loads nothing by default", function()
    setup()
    eq({}, require("org.extensions").loaded)
    eq(nil, require("org.actions").list.testext_hello)
  end)

  it("merges defaults under the user's options and calls setup", function()
    setup({ extensions = { testext = { list = { 3 }, nested = { b = 20 } } } })
    local opts = require("org.extensions").opts("testext")
    eq("hi", opts.greeting)
    eq({ 3 }, opts.list)
    eq({ a = 1, b = 20 }, opts.nested)
    eq(opts, require("org.config").opts.extensions.testext)
    eq(1, #calls)
    eq(opts, calls[1])
  end)

  it("accepts true and skips false or enabled = false", function()
    setup({ extensions = { testext = true } })
    ok(require("org.extensions").enabled("testext"))
    setup({ extensions = { testext = false } })
    ok(not require("org.extensions").enabled("testext"))
    setup({ extensions = { testext = { enabled = false } } })
    ok(not require("org.extensions").enabled("testext"))
    eq(1, #calls)
  end)

  it("registers actions, commands and default keys, and removes them when turned off", function()
    setup({ extensions = { testext = {} } })
    ok(require("org.actions").list.testext_hello)
    ok(require("org.commands").extra.testext_cmd)
    eq("<prefix>zz", require("org.config").opts.mappings.global.testext_hello)
    require("org.actions").run("testext_hello")
    ok(calls.hello)
    setup()
    eq(nil, require("org.actions").list.testext_hello)
    eq(nil, require("org.commands").extra.testext_cmd)
  end)

  it("removes its global keys when turned off", function()
    setup({ extensions = { testext = {} } })
    local lhs = require("org.config").lhs_list("<prefix>zz")[1]
    ok(vim.fn.maparg(lhs, "n", false, true).desc)
    setup()
    eq(nil, vim.fn.maparg(lhs, "n", false, true).desc)
  end)

  it("leaves a key the user remapped after setup", function()
    setup({ extensions = { testext = {} } })
    local lhs = require("org.config").lhs_list("<prefix>zz")[1]
    vim.keymap.set("n", lhs, "<Nop>", { desc = "mine" })
    setup()
    eq("mine", vim.fn.maparg(lhs, "n", false, true).desc)
    vim.keymap.del("n", lhs)
  end)

  it("keeps a key the user set", function()
    setup({ mappings = { global = { testext_hello = false } }, extensions = { testext = {} } })
    eq(false, require("org.config").opts.mappings.global.testext_hello)
  end)

  it("adds no keys to a mapping section the user turned off", function()
    package.loaded["org.extensions.testext"].mappings.emacs_global = { testext_hello = "<C-c>z" }
    setup({ mappings = { emacs_global = false }, extensions = { testext = {} } })
    eq(false, require("org.config").opts.mappings.emacs_global)
    eq("", vim.fn.maparg("<C-c>z", "n"))
    eq("<prefix>zz", require("org.config").opts.mappings.global.testext_hello)
  end)

  it("adds its which-key groups", function()
    local added = {}
    package.loaded["which-key"] = {
      add = function(spec)
        vim.list_extend(added, spec)
      end,
    }
    package.loaded["org.extensions.testext"].groups = { { "z", "test ext" } }
    setup({ extensions = { testext = {} } })
    package.loaded["which-key"] = nil
    local prefix = require("org.config").lhs_list("<prefix>z")[1]
    local labels = {}
    for _, g in ipairs(added) do
      labels[g[1]] = g.group
    end
    eq("test ext", labels[prefix])
    eq("narrow", labels[require("org.config").lhs_list("<prefix>n")[1]])
  end)

  it("calls teardown when a later setup turns it off or sets it up again", function()
    local downs = 0
    package.loaded["org.extensions.testext"].teardown = function()
      downs = downs + 1
    end
    setup({ extensions = { testext = {} } })
    eq(0, downs)
    setup({ extensions = { testext = {} } })
    eq(1, downs)
    setup()
    eq(2, downs)
    setup()
    eq(2, downs)
  end)

  it("reports an unknown extension without failing setup", function()
    local errors = {}
    local notify = vim.notify
    vim.notify = function(msg)
      errors[#errors + 1] = msg
    end
    setup({ extensions = { no_such_extension = {} } })
    vim.notify = notify
    ok(errors[1] and errors[1]:find("no_such_extension", 1, true), vim.inspect(errors))
    ok(not require("org.extensions").enabled("no_such_extension"))
  end)
end)

describe("built-in extensions", function()
  --- Every module under lua/org/extensions/ except the loader.
  local function extension_names()
    local names = {}
    local dir = vim.fn.getcwd() .. "/lua/org/extensions"
    for name, kind in vim.fs.dir(dir) do
      if kind == "file" and name:match("%.lua$") and name ~= "init.lua" then
        names[#names + 1] = name:gsub("%.lua$", "")
      elseif kind == "directory" and vim.uv.fs_stat(dir .. "/" .. name .. "/init.lua") then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    return names
  end

  it("give default keys that clash with no org.nvim key or other extension", function()
    local config = require("org.config")
    local actions = require("org.actions").list
    -- mode + key -> owner, for org.nvim's default keys
    local keys = {}
    local function add(entries, owner, section, name, value, ext_actions)
      local a = (ext_actions or {})[name] or actions[name]
      local modes = (section == "org_insert" or section == "emacs_insert") and { "i" } or (a and a.modes or { "n" })
      for _, lhs in ipairs(config.lhs_list(value)) do
        for _, mode in ipairs(modes) do
          entries[#entries + 1] = { mode = mode, key = vim.keycode(lhs), lhs = lhs, owner = owner .. "." .. name }
        end
      end
    end
    local sections = { "global", "emacs_global", "org", "emacs", "org_insert", "emacs_insert" }
    for _, section in ipairs(sections) do
      for name, value in pairs(config.defaults.mappings[section] or {}) do
        add(keys, section, section, name, value)
      end
    end
    local clashes = {}
    local ext_keys = {}
    for _, ext_name in ipairs(extension_names()) do
      local ext = require("org.extensions." .. ext_name)
      for section, maps in pairs(ext.mappings or {}) do
        for name, value in pairs(maps) do
          add(ext_keys, ext_name, section, name, value, ext.actions)
        end
      end
    end
    for i, e in ipairs(ext_keys) do
      local others = vim.list_extend(vim.list_slice(ext_keys, i + 1), keys)
      for _, o in ipairs(others) do
        local short, long = e.key, o.key
        if #short > #long then
          short, long = long, short
        end
        if e.mode == o.mode and e.owner ~= o.owner and long:sub(1, #short) == short then
          clashes[#clashes + 1] = string.format("%s %s (%s) / %s (%s)", e.mode, e.lhs, e.owner, o.lhs, o.owner)
        end
      end
    end
    table.sort(clashes)
    eq({}, clashes)
  end)
end)
