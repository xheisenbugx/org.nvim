-- q quits a menu or view only when nothing else in it uses q; <Esc> always
-- quits. The agenda keeps q (and not <Esc>), as in Emacs.

local utils = require("org.utils")
local ui = require("org.ui")

--- Run `fn` with utils.getchar answering `keys` in turn (nil = <Esc>).
local function with_keys(keys, fn)
  local orig = utils.getchar
  local i = 0
  utils.getchar = function()
    i = i + 1
    return keys[i]
  end
  local ok_, res = pcall(fn)
  utils.getchar = orig
  assert(ok_, res)
  return res
end

describe("menu quit keys", function()
  it("q quits a menu that has no q entry", function()
    local items = { { key = "a", label = "a", value = "a" } }
    eq(
      nil,
      with_keys({ "q", "a" }, function()
        return ui.menu({ title = "t", items = items })
      end)
    )
    eq(true, ui.q_quits(items))
  end)

  it("q picks the entry that uses it", function()
    local items = { { key = "a", label = "a", value = "a" }, { key = "q", label = "q", value = "QUIT" } }
    eq(false, ui.q_quits(items))
    eq(
      "QUIT",
      with_keys({ "q" }, function()
        return ui.menu({ title = "t", items = items })
      end)
    )
  end)

  it("a TODO keyword with the key q is chosen with q", function()
    org_buffer({ "#+TODO: TODO(t) QUIT(q) | DONE(d)", "* TODO Task" }, { 2, 0 })
    with_keys({ "q" }, function()
      require("org.todo").select(nil, {})
    end)
    eq("* QUIT Task", buf_lines(0)[2])
  end)

  it("q quits the TODO menu when no keyword uses it", function()
    org_buffer({ "#+TODO: TODO(t) | DONE(d)", "* TODO Task" }, { 2, 0 })
    with_keys({ "q" }, function()
      require("org.todo").select(nil, {})
    end)
    eq("* TODO Task", buf_lines(0)[2])
  end)

  it("q quits a choice list", function()
    local orig = ui._force_float
    ui._force_float = true
    local got = with_keys({ "q" }, function()
      return ui.choose({ prompt = "Pick: ", items = { "a", "b" } })
    end)
    ui._force_float = orig
    eq(nil, got)
  end)

  it("q picks an attachment command bound to q in expert mode", function()
    local attach = require("org.attach")
    local cmds, opts = attach.commands, require("org.config").opts.attach
    local expert, ran = opts and opts.expert, nil
    attach.commands = function()
      return { {
        "q",
        "custom",
        function()
          ran = true
        end,
      } }
    end
    require("org.config").opts.attach = vim.tbl_extend("force", opts or {}, { expert = true })
    org_buffer({ "* H" }, { 1, 0 })
    with_keys({ "q" }, function()
      attach.menu()
    end)
    attach.commands = cmds
    require("org.config").opts.attach.expert = expert
    eq(true, ran)
  end)
end)

describe("view keys", function()
  local views = require("org.extensions.views_util")

  it("q in a list of alternatives gives way to another key using it", function()
    eq({ "<Esc>", "q" }, views.lhs({ quit = { "<Esc>", "q" }, refresh = "r" }, "quit"))
    eq({ "<Esc>" }, views.lhs({ quit = { "<Esc>", "q" }, refresh = "q" }, "quit"))
    eq({ "<Esc>" }, views.lhs({ quit = { "<Esc>", "q" } }, "quit", { grade = { "q" } }))
    -- a single key is kept: it is what the user asked for
    eq({ "q" }, views.lhs({ quit = "q", refresh = "q" }, "quit"))
    eq({}, views.lhs({ quit = false }, "quit"))
  end)

  it("hints q/Esc when both quit", function()
    eq("q/Esc", views.key_hint({ quit = { "<Esc>", "q" } }, "quit"))
    eq("<Esc>", views.key_hint({ quit = { "<Esc>", "q" }, refresh = "q" }, "quit"))
    eq("<CR>", views.key_hint({ jump = "<CR>" }, "jump"))
    eq(nil, views.key_hint({ quit = false }, "quit"))
  end)
end)

describe("agenda tag filter", function()
  local config = require("org.config")
  local view = require("org.agenda.view")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/q.org"

  local function filter(tags_line, keys)
    utils.writefile(path, { tags_line, "* TODO Quiet :quiet:", "* TODO Work :work:" })
    config.setup({ agenda_files = { path }, org_directory = dir })
    require("org.agenda").open({ blocks = { { type = "todo" } } })
    with_keys(keys, function()
      view.filter_by_tag()
    end)
    local f = view.state.filters.tag
    pcall(view.quit, true)
    local b = utils.find_buffer(path)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    config.setup({})
    return f
  end

  it("q filters by the tag whose key is q", function()
    eq({ "+quiet" }, filter("#+TAGS: quiet(q) work(w)", { "q" }))
  end)

  it("q quits when no tag uses it", function()
    eq({}, filter("#+TAGS: work(w)", { "q" }))
  end)
end)
