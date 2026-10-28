-- Edge cases of the literate extension: what is and isn't trusted (a
-- sibling directory sharing the prefix of `allow`, `:tangle no`, a damaged
-- trust file), files with no Lua, unnamed buffers, spaces and unicode.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local utils = require("org.utils")
local literate = require("org.extensions.literate")

local base, dir
local saved = {}

local function stub(mod, name, fn)
  saved[#saved + 1] = { mod, name, mod[name] }
  mod[name] = fn
end

local function setup(lit)
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
    extensions = {
      literate = vim.tbl_extend("force", { files = {}, notify = false, allow = { dir }, confirm = false }, lit or {}),
    },
  })
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  return path
end

local function init(tangle, body)
  return {
    "#+PROPERTY: header-args:lua :tangle " .. (tangle or "out.lua"),
    "* Block",
    "#+begin_src lua",
    body or "vim.g.lit_edge = (vim.g.lit_edge or 0) + 1",
    "#+end_src",
  }
end

-- opening a file runs nothing: a block runs once its text changed, so
-- change the line of the block's body (line 4 of `init`)
local function touch(lnum, text)
  vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { text })
end

describe("literate edge cases", function()
  before_each(function()
    base = utils.realpath(vim.fn.tempname()) or vim.fn.tempname()
    base = vim.fs.normalize(base)
    dir = base .. "/nvim"
    vim.fn.mkdir(dir, "p")
    vim.g.lit_edge = nil
    stub(utils, "notify", function() end)
    vim.fn.delete(literate.trust_file())
    literate.teardown()
    setup()
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      local s = saved[i]
      s[1][s[2]] = s[3]
    end
    saved = {}
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(base, "rf")
    vim.fn.delete(literate.trust_file())
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
  end)

  it("doesn't trust a sibling directory whose name starts like an allowed one", function()
    local evil = write(base .. "/nvim-evil/init.org", init())
    vim.cmd("edit " .. vim.fn.fnameescape(evil))
    eq(nil, literate.kind(0))
    vim.cmd("silent write")
    eq(nil, vim.g.lit_edge)
    eq(nil, vim.uv.fs_stat(base .. "/nvim-evil/out.lua"))
  end)

  it("trusts files in subdirectories of an allowed one", function()
    local deep = write(dir .. "/lua/sub/init.org", init())
    vim.cmd("edit " .. vim.fn.fnameescape(deep))
    eq("detected", literate.kind(0))
    touch(4, "vim.g.lit_edge = 1")
    vim.cmd("silent write")
    eq(1, vim.g.lit_edge)
  end)

  it("doesn't detect a file whose Lua blocks don't tangle", function()
    vim.cmd("edit " .. vim.fn.fnameescape(write(dir .. "/no.org", init("no"))))
    eq(nil, literate.kind(0))
    vim.cmd("silent write")
    eq(nil, vim.g.lit_edge)
  end)

  it("detects a lowercase #+property line", function()
    local lines = init()
    lines[1] = lines[1]:lower()
    vim.cmd("edit " .. vim.fn.fnameescape(write(dir .. "/lower.org", lines)))
    eq("detected", literate.kind(0))
  end)

  it("never trusts an unnamed buffer", function()
    vim.cmd("enew")
    vim.bo.filetype = "org"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, init())
    eq(nil, literate.kind(0))
    eq(false, literate.trusted(vim.api.nvim_get_current_buf()))
  end)

  it("asks again after the trust file was damaged", function()
    local asked = 0
    stub(utils, "confirm", function()
      asked = asked + 1
      return true
    end)
    vim.fn.mkdir(vim.fs.dirname(literate.trust_file()), "p")
    vim.fn.writefile({ "{ this is not json" }, literate.trust_file())
    literate.teardown()
    setup({ confirm = true })
    vim.cmd("edit " .. vim.fn.fnameescape(write(dir .. "/init.org", init())))
    touch(4, "vim.g.lit_edge = 1")
    vim.cmd("silent write")
    eq(1, asked)
    eq(1, vim.g.lit_edge)
    -- the answer replaced the damaged file
    local t = vim.json.decode(table.concat(vim.fn.readfile(literate.trust_file()), "\n"))
    eq(true, t[utils.realpath(dir .. "/init.org")])
  end)

  it("saves a literate file with no Lua blocks without tangling or running", function()
    vim.cmd("edit " .. vim.fn.fnameescape(write(dir .. "/empty.org", { "#+PROPERTY: header-args:lua :tangle e.lua" })))
    eq("detected", literate.kind(0))
    local res = literate.on_save(vim.api.nvim_get_current_buf())
    eq(0, res.ran)
    eq({}, res.errors)
    eq({}, literate.lua_blocks(vim.api.nvim_get_current_buf()))
  end)

  it("handles a directory with spaces and unicode in its name", function()
    local odd = base .. "/my conf ñ/nvim"
    setup({ allow = { odd } })
    local path = write(odd .. "/init.org", init())
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    eq("detected", literate.kind(0))
    touch(4, 'vim.g.lit_edge = "héllo ✓"')
    vim.cmd("silent write")
    eq("héllo ✓", vim.g.lit_edge)
    eq(1, vim.fn.filereadable(odd .. "/out.lua"))
  end)

  it("reports a block that doesn't compile and still runs the others", function()
    vim.cmd("edit " .. vim.fn.fnameescape(write(dir .. "/init.org", {
      "#+PROPERTY: header-args:lua :tangle out.lua",
      "* Broken",
      "#+begin_src lua",
      "local x = 1",
      "#+end_src",
      "* Fine",
      "#+begin_src lua",
      "vim.g.lit_edge = 0",
      "#+end_src",
    })))
    touch(4, "local x = = 1")
    touch(8, "vim.g.lit_edge = 42")
    local res = literate.on_save(vim.api.nvim_get_current_buf())
    eq(42, vim.g.lit_edge)
    eq(1, #res.errors)
  end)

  it("runs an unchanged block only once across saves", function()
    vim.cmd("edit " .. vim.fn.fnameescape(write(dir .. "/init.org", init())))
    vim.cmd("silent write")
    eq(nil, vim.g.lit_edge, "opening and saving unchanged runs nothing")
    touch(4, "vim.g.lit_edge = (vim.g.lit_edge or 0) + 10")
    vim.cmd("silent write")
    vim.cmd("silent write")
    vim.cmd("silent write")
    eq(10, vim.g.lit_edge)
  end)
end)
