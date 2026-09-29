-- org-ctags: plain links through tags files. The ctags program is a fake
-- (Exuberant / Universal ctags are not installed here): a shell script that
-- writes a Vim tags file for the <<targets>> of the Org files. Buffer texts
-- of new topics come from Emacs 9.8.10 (org-ctags-append-topic,
-- org-ctags-open-file).
local config = require("org.config")
local utils = require("org.utils")
local ctags = require("org.ctags")
vim.g.org_test = true

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir)
end

local FAKE = {
  "#!/bin/sh",
  'out=""; dir=""',
  'echo "$@" > "$FAKE_CTAGS_ARGS"',
  'while [ $# -gt 0 ]; do case "$1" in -f) out="$2"; shift 2;; -R) dir="$2"; shift 2;; *) shift;; esac; done',
  "awk '{ line=$0; while (match(line, /<<[^<>]+>>/)) { "
    .. 'printf "%s\\t%s\\t%d;\\"\\td\\n", substr(line, RSTART+2, RLENGTH-4), FILENAME, FNR; '
    .. "line=substr(line, RSTART+RLENGTH) } }' \"$dir\"/*.org | LC_ALL=C sort > \"$out\"",
}

local function setup(dir, extra)
  local fake = dir .. "/fake-ctags"
  utils.writefile(fake, FAKE)
  vim.fn.setfperm(fake, "rwxr-xr-x")
  vim.env.FAKE_CTAGS_ARGS = dir .. "/args"
  config.setup(vim.tbl_deep_extend("force", { ctags = { enabled = true, path_to_ctags = fake } }, extra or {}))
end

local function answers(list)
  local orig = utils.confirm
  local asked = {}
  utils.confirm = function(q)
    asked[#asked + 1] = q
    return table.remove(list, 1)
  end
  return asked, function()
    utils.confirm = orig
  end
end

describe("org-ctags", function()
  after_each(function()
    vim.cmd("silent! %bwipeout!")
    config.setup({})
  end)

  it("creates the tags file and reads the tags back", function()
    local dir = tmpdir()
    setup(dir)
    utils.writefile(dir .. "/a.org", { "* Intro", "See [[Target]]." })
    utils.writefile(dir .. "/b.org", { "* <<Target>>", "text <<Other place>>" })
    vim.cmd("edit! " .. dir .. "/a.org")
    ok(ctags.create_tags())
    local args = utils.readfile(dir .. "/args")[1]
    eq(
      "--langdef=orgmode --langmap=orgmode:.org --regex-orgmode=/<<([^<>]+)>>/\\1/d,definition/ -f "
        .. dir
        .. "/tags -R "
        .. dir,
      args
    )
    eq({ "Other place", "Target" }, ctags.all_tags())
    local where = ctags.get_filename_for_tag("Other place")
    eq(dir .. "/b.org", where.filename)
    eq(nil, ctags.get_filename_for_tag("Missing"))
  end)

  it("follows a plain link to the tag in another file", function()
    local dir = tmpdir()
    setup(dir)
    utils.writefile(dir .. "/a.org", { "* Intro", "See [[Target]]." })
    utils.writefile(dir .. "/b.org", { "* Other", "** <<Target>>" })
    vim.cmd("edit! " .. dir .. "/a.org")
    ctags.create_tags()
    vim.api.nvim_win_set_cursor(0, { 2, 7 })
    ok(require("org.links").open_at_point(0))
    eq(dir .. "/b.org", vim.api.nvim_buf_get_name(0))
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("rebuilds the tags when asked, then offers a new topic", function()
    local dir = tmpdir()
    setup(dir)
    utils.writefile(dir .. "/a.org", { "* A", "body" })
    vim.cmd("edit! " .. dir .. "/a.org")
    -- no tags file yet: rebuild? yes -> still missing; append? yes
    local asked, restore = answers({ true, true })
    ok(ctags.open_link("new topic"))
    restore()
    eq("Tag `new topic' not found.  Rebuild table `" .. dir .. "/tags' and look again?", asked[1])
    eq("Topic `new topic' not found; append to end of buffer?", asked[2])
    ok(utils.exists(dir .. "/tags"))
    -- Emacs 9.8.10: "* A\nbody\n\n\n* <<New Topic>>\n\n\n\n\n\n", point on line 9
    eq({ "* A", "body", "", "", "* <<New Topic>>", "", "", "", "", "" }, buf_lines())
    eq(9, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("falls back to the buffer search when every function declines", function()
    local dir = tmpdir()
    setup(dir)
    utils.writefile(dir .. "/a.org", { "* A", "[[B]]", "* B" })
    vim.cmd("edit! " .. dir .. "/a.org")
    local _, restore = answers({ false, false })
    vim.api.nvim_win_set_cursor(0, { 2, 2 })
    require("org.links").open_at_point(0)
    restore()
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    eq({ "* A", "[[B]]", "* B" }, buf_lines())
  end)

  it("does nothing when disabled", function()
    config.setup({})
    eq(nil, ctags.open_link("x"))
  end)

  it("visits or creates NAME.org with a new topic", function()
    local dir = tmpdir()
    setup(dir, { ctags = { open_link_functions = { "ask_visit_buffer_or_file" } } })
    vim.cmd("cd " .. dir)
    local asked, restore = answers({ true })
    ok(ctags.open_link("my title"))
    restore()
    eq("File `my title.org' not found; create?", asked[1])
    eq(dir .. "/my title.org", vim.api.nvim_buf_get_name(0))
    -- Emacs 9.8.10 (org-ctags-open-file on a new file): "* <<My Title>>\n\n\n\n\n\n"
    eq({ "* <<My Title>>", "", "", "", "", "" }, buf_lines())
    vim.cmd("silent! write")
    vim.cmd("enew")
    ok(ctags.visit_buffer_or_file("my title"))
    eq(dir .. "/my title.org", vim.api.nvim_buf_get_name(0))
    vim.cmd("cd -")
  end)

  it("find_tag_interactive jumps to a known tag or runs the functions", function()
    local dir = tmpdir()
    setup(dir, { ctags = { open_link_functions = { "append_topic" } } })
    utils.writefile(dir .. "/b.org", { "* x", "* <<Here>>" })
    vim.cmd("edit! " .. dir .. "/b.org")
    ctags.create_tags()
    local orig = utils.input_complete
    local cands
    utils.input_complete = function(_, c)
      cands = c
      return "Here"
    end
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    ok(ctags.find_tag_interactive())
    eq({ "Here" }, cands)
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
    utils.input_complete = function()
      return "elsewhere"
    end
    ok(ctags.find_tag_interactive())
    utils.input_complete = orig
    eq("* <<Elsewhere>>", buf_lines()[5])
  end)
end)
