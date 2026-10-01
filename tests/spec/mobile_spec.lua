local config = require("org.config")
local mobile = require("org.mobile")
local utils = require("org.utils")
vim.g.org_test = true

local initial = { org_directory = config.opts.org_directory, agenda_files = config.opts.agenda_files }

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return require("org.utils").realpath(dir)
end

local function read(path)
  local fd = assert(io.open(path, "rb"))
  local s = fd:read("*a")
  fd:close()
  return s
end

--- An org directory with a.org (plus `extra` files) and a staging directory.
local function setup(files, opts)
  local dir = tmpdir()
  vim.fn.mkdir(dir .. "/org", "p")
  vim.fn.mkdir(dir .. "/stage", "p")
  for name, lines in pairs(files) do
    utils.writefile(dir .. "/org/" .. name, lines)
  end
  config.setup(vim.tbl_deep_extend("force", {
    org_directory = dir .. "/org",
    agenda_files = { dir .. "/org/a.org" },
    id = { locations_file = dir .. "/ids.json" },
    tags_column = 0,
    mobile = {
      directory = dir .. "/stage",
      inbox_for_pull = dir .. "/org/from-mobile.org",
      show_flagged = false,
    },
  }, opts or {}))
  require("org.id")._reset()
  return dir
end

local function wipe_buffers(dir)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if dir and name:sub(1, #dir) == dir then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

local function buffer_of(path)
  return utils.load_buffer(path)
end

local today = os.date("%Y-%m-%d %a")

describe("org-mobile", function()
  local dir
  after_each(function()
    wipe_buffers(dir)
    config.setup(initial)
    require("org.id")._reset()
  end)

  it("computes MD5 digests like Emacs's md5", function()
    eq("d41d8cd98f00b204e9800998ecf8427e", mobile.md5(""))
    eq("68b329da9893e34099c7d8ad5cb9c940", mobile.md5("\n"))
    eq("9e107d9d372bb6826bd81d3542a419d6", mobile.md5("The quick brown fox jumps over the lazy dog"))
    eq("7707d6ae4e027c70eea2a935c2296f21", mobile.md5(string.rep("a", 1000000)))
  end)

  it("pushes the files, index.org, agendas.org and checksums.dat", function()
    dir = setup({
      ["a.org"] = {
        "* TODO [#A] Task one :work:",
        "  SCHEDULED: <" .. today .. ">",
        "  Body of task one.",
        "* Plain :home:",
        "** NEXT Sub task",
      },
    }, { todo_keywords = { "TODO NEXT | DONE" }, tags = { "work(w) home(h)" } })
    ok(mobile.push())
    local stage = dir .. "/stage"
    eq({
      "#+READONLY",
      "#+TODO: TODO NEXT | DONE",
      "#+TAGS: work home",
      "#+ALLPRIORITIES: A B C",
      "* [[file:agendas.org][Agenda Views]]",
      "* [[file:a.org][a.org]]",
    }, utils.readfile(stage .. "/index.org"))
    eq("\n", read(stage .. "/mobileorg.org"))
    -- agenda entries got IDs, saved before the copy
    local a = utils.readfile(dir .. "/org/a.org")
    eq(a, utils.readfile(stage .. "/a.org"))
    local id1, id2
    for i, l in ipairs(a) do
      local id = l:match("^:ID:%s+(%S+)")
      if id and not id1 then
        id1 = id
        eq("* TODO [#A] Task one :work:", a[1])
        ok(i < 6)
      elseif id then
        id2 = id
      end
    end
    ok(id1 and id2)
    local sums = utils.readfile(stage .. "/checksums.dat")
    eq(4, #sums)
    eq(mobile.md5(read(stage .. "/index.org")) .. "  index.org", sums[1])
    eq("68b329da9893e34099c7d8ad5cb9c940  mobileorg.org", sums[2])
    ok(sums[3]:match("^%x+  a%.org$"))
    eq(mobile.md5(read(stage .. "/agendas.org")) .. "  agendas.org", sums[4])
    local ag = utils.readfile(stage .. "/agendas.org")
    eq("#+READONLY", ag[1])
    ok(ag[2]:match("^%* Week%-agenda %(W%d+%):<after>KEYS=a TITLE: Agenda</after>$"), ag[2])
    local text = table.concat(ag, "\n")
    ok(text:find("\n* ToDo: ALL<after>KEYS=t TITLE: ALL TODO</after>\n", 1, true))
    ok(text:find("\n***  TODO [#A] Task one", 1, true))
    ok(text:find("\n**  TODO [#A] Task one", 1, true))
    ok(text:find("<before>a:%s+Scheduled:%s*</before>\n   SCHEDULED: <"), text)
    ok(text:find("\n   SCHEDULED: <" .. today .. ">\n   Body of task one.\n", 1, true))
    ok(text:find("   :PROPERTIES:\n   :ORIGINAL_ID: " .. id1 .. "\n   :END:\n\n", 1, true))
    ok(text:find("**  NEXT Sub task", 1, true))
    ok(text:find(":ORIGINAL_ID: " .. id2, 1, true))
  end)

  it("uses outline path links without forced IDs", function()
    dir = setup(
      { ["a.org"] = { "* Project", "** TODO Sub: task/x" } },
      { mobile = { force_id_on_agenda_items = false } }
    )
    ok(mobile.push())
    eq({ "* Project", "** TODO Sub: task/x" }, utils.readfile(dir .. "/org/a.org"))
    local text = read(dir .. "/stage/agendas.org")
    ok(text:find(":ORIGINAL_ID: olp:a.org:Project/Sub%3A task%2Fx\n", 1, true), text)
  end)

  it("lists the staged files relative to org_directory", function()
    dir = setup({ ["a.org"] = { "* A" }, ["b.org"] = { "* B" }, ["skip.org"] = { "* S" } })
    vim.fn.mkdir(dir .. "/org/sub", "p")
    utils.writefile(dir .. "/org/sub/c.org", { "* C" })
    config.opts.mobile.files = { "agenda_files", dir .. "/org/sub", "b.org", dir .. "/org/skip.org" }
    config.opts.mobile.files_exclude_regexp = "skip"
    local links = vim.tbl_map(function(e)
      return e.link
    end, mobile.files_alist())
    eq({ "a.org", "sub/c.org", "b.org" }, links)
  end)

  it("builds the SUMO agenda from the custom commands (org-mobile-agendas)", function()
    dir = setup({ ["a.org"] = { "* A" } }, {
      agenda = {
        custom_commands = {
          b = {
            description = "Block",
            blocks = { { type = "agenda", span = "day" }, { type = "todo", match = "NEXT" } },
          },
          s = { description = "Search", type = "search", match = "foo" },
          e = { description = "Empty", type = "tags", match = "" },
          w = { description = "", type = "tags_todo", match = "work" },
          p = "Prefix",
        },
      },
    })
    local function titles()
      return vim.tbl_map(function(b)
        return b.mobile_title
      end, mobile.sumo_blocks())
    end
    eq({
      "<after>KEYS=a TITLE: Agenda</after>",
      "<after>KEYS=t TITLE: ALL TODO</after>",
      "<after>KEYS=b#1 TITLE: Block</after>",
      "<after>KEYS=b#2 TITLE: Block</after>",
      "<after>KEYS=w TITLE: tags_todo</after>",
    }, titles())
    config.opts.mobile.agendas = "default"
    eq({ "<after>KEYS=a TITLE: Agenda</after>", "<after>KEYS=t TITLE: All TODO</after>" }, titles())
    config.opts.mobile.agendas = { "w", "t" }
    eq({ "<after>KEYS=w TITLE: tags_todo</after>", "<after>KEYS=t TITLE: All TODO</after>" }, titles())
    eq({ dir .. "/org/a.org" }, mobile.sumo_blocks()[1].files)
  end)

  it("pulls captures and applies edits, flags and errors like org-mobile-apply", function()
    dir = setup({
      ["a.org"] = {
        "* TODO [#B] Task one :work:",
        ":PROPERTIES:",
        ":ID:       id-one",
        ":END:",
        "Body of task one.",
        "* TODO Task two",
        ":PROPERTIES:",
        ":ID:       id-two",
        ":END:",
        "* Project",
        "** Child A",
        "** Child B",
        "* Target",
        ":PROPERTIES:",
        ":ID:       id-target",
        ":END:",
        "* DONE Old one",
        ":PROPERTIES:",
        ":ID:       id-old",
        ":END:",
      },
    })
    require("org.id").update_locations()
    ok(mobile.push())
    utils.writefile(dir .. "/org/from-mobile.org", { "* Earlier entry" })
    utils.writefile(dir .. "/stage/mobileorg.org", {
      "* A new capture",
      "Some text",
      "* F(edit:todo) [[id:id-one][Task one]]",
      "** Old value",
      "TODO",
      "** New value",
      "DONE",
      "** End of edit",
      "* F(edit:tags) [[id:id-one][Task one]]",
      "** Old value",
      ":work:",
      "** New value",
      ":work:urgent:",
      "** End of edit",
      "* F(edit:priority) [[id:id-two][Task two]]",
      "** Old value",
      "** New value",
      "A",
      "** End of edit",
      "* F(edit:heading) [[id:id-two][Task two]]",
      "** Old value",
      "Task two",
      "** New value",
      "Task two renamed",
      "** End of edit",
      "* F(edit:body) [[olp:a.org:Project/Child B][Child B]]",
      "** Old value",
      "** New value",
      "New body",
      "second body line",
      "** End of edit",
      "* F(edit:heading) [[id:id-old][Old one]]",
      "** Old value",
      "Something else",
      "** New value",
      "Changed",
      "** End of edit",
      "* F() [[id:id-two][Task two]]",
      "Please call Bob",
      "second line",
      "* F(edit:addheading) [[olp:a.org:Project][Project]]",
      "** Old value",
      "** New value",
      "Child C",
      "** End of edit",
      "* F(edit:refile) [[olp:a.org:Project/Child A][Child A]]",
      "** Old value",
      "** New value",
      "id:id-target",
      "** End of edit",
      "* F(edit:todo) [[id:nope][Missing]]",
      "** Old value",
      "TODO",
      "** New value",
      "DONE",
      "** End of edit",
      "* F(edit:heading) [[olp:a.org:Nowhere][x]]",
      "* F(bogus) [[id:id-old][Old one]]",
      "** Note ID: 1234-ABCD",
    })
    local counts = mobile.pull()
    eq(1, counts.new)
    eq(11, counts.edits)
    eq(1, counts.flags)
    eq(4, counts.errors)
    eq({ dir .. "/org/a.org" }, counts.flagged_files)
    eq({
      "* Earlier entry",
      "* A new capture",
      "Some text",
      "* Heading changed in the mobile device and on the computer F(edit:heading) [[id:id-old][Old one]]",
      "** Old value",
      "Something else",
      "** New value",
      "Changed",
      "** End of edit",
      "* BAD REFERENCE F(edit:todo) [[id:nope][Missing]]",
      "** Old value",
      "TODO",
      "** New value",
      "DONE",
      "** End of edit",
      "* Heading not found on level 1: Nowhere F(edit:heading) [[olp:a.org:Nowhere][x]]",
      "BAD FLAG * F(bogus) [[id:id-old][Old one]]",
    }, utils.readfile(dir .. "/org/from-mobile.org"))
    local lines = buf_lines(buffer_of(dir .. "/org/a.org"))
    ok(lines[1]:match("^#%+LAST_MOBILE_CHANGE: %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$"), lines[1])
    eq({
      "* DONE [#B] Task one :work:urgent:",
      ":PROPERTIES:",
      ":ID:       id-one",
      ":END:",
      "Body of task one.",
      "* TODO [#A] Task two renamed :FLAGGED:",
      ":PROPERTIES:",
      ":ID:       id-two",
      ":THEFLAGGINGNOTE: Please call Bob\\nsecond line\\n",
      ":END:",
      "* Project",
      "** Child B",
      "New body",
      "second body line",
      "** Child C",
      "* Target",
      ":PROPERTIES:",
      ":ID:       id-target",
      ":END:",
      "** Child A",
      "* DONE Old one",
      ":PROPERTIES:",
      ":ID:       id-old",
      ":END:",
    }, vim.list_slice(lines, 2))
    eq("", read(dir .. "/stage/mobileorg.org"))
    ok(read(dir .. "/stage/checksums.dat"):find("d41d8cd98f00b204e9800998ecf8427e  mobileorg.org\n", 1, true))
    -- nothing new the second time
    eq(nil, mobile.pull())
  end)

  it("forces mobile changes of the listed kinds (org-mobile-force-mobile-change)", function()
    dir = setup({ ["a.org"] = { "* TODO Task :x:", ":PROPERTIES:", ":ID: t1", ":END:" } })
    local bufnr = buffer_of(dir .. "/org/a.org")
    local t = { bufnr = bufnr, lnum = 1 }
    local okh, err = pcall(mobile.edit, "heading", "Other", "New title", t)
    eq(false, okh)
    eq("Heading changed in the mobile device and on the computer", err)
    config.opts.mobile.force_mobile_change = { "heading" }
    ok(mobile.edit("heading", "Other", "New title", t))
    eq("* TODO New title :x:", buf_lines(bufnr)[1])
    local okt, terr = pcall(mobile.edit, "todo", "WAIT", "DONE", t)
    eq(false, okt)
    eq('State before change was expected as "WAIT", but is "TODO"', terr)
    config.opts.mobile.force_mobile_change = true
    ok(mobile.edit("tags", "y", "a:b", t))
    eq("* TODO New title :a:b:", buf_lines(bufnr)[1])
    ok(mobile.bodies_same("  a \n\n b\n", "a\nb"))
    ok(mobile.tags_same({ "a", "b" }, { "b", "a" }))
  end)

  it("shows and removes the flagging note from the FLAGGED agenda", function()
    dir = setup({ ["a.org"] = { "* Task :FLAGGED:", ":PROPERTIES:", ":THEFLAGGINGNOTE: Call\\nBob", ":END:" } })
    require("org.agenda").command("?")
    local view = require("org.agenda.view")
    local line
    for l, it in pairs(view.state.line_items) do
      if it.headline then
        line = l
      end
    end
    ok(line)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    local agenda_win = vim.api.nvim_get_current_win()
    mobile.show_flagging_note()
    eq("Call\\nBob", vim.fn.getreg('"'))
    eq(agenda_win, vim.api.nvim_get_current_win())
    local note_buf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):match("%*Flagging Note%*$") then
        note_buf = b
      end
    end
    eq({ "Call", "Bob" }, buf_lines(note_buf))
    local confirm = utils.confirm
    utils.confirm = function()
      return true
    end
    local okc, err = pcall(mobile.show_flagging_note)
    utils.confirm = confirm
    ok(okc, err)
    eq({ "* Task" }, buf_lines(buffer_of(dir .. "/org/a.org")))
    pcall(view.quit, true)
    pcall(vim.api.nvim_buf_delete, note_buf, { force = true })
  end)

  it("encrypts the staged files and decrypts mobileorg.org", function()
    if vim.fn.executable("openssl") == 0 then
      return
    end
    dir = setup({ ["a.org"] = { "* TODO Task", ":PROPERTIES:", ":ID: e1", ":END:" } }, {
      mobile = { use_encryption = true, encryption_password = "secret" },
    })
    require("org.id").update_locations()
    ok(mobile.push())
    local stage = dir .. "/stage"
    ok(read(stage .. "/a.org"):sub(1, 8) == "Salted__")
    local out = dir .. "/plain"
    mobile.decrypt_file(stage .. "/a.org", out)
    eq(read(dir .. "/org/a.org"), read(out))
    mobile.decrypt_file(stage .. "/index.org", out)
    eq("#+READONLY", utils.readfile(out)[1])
    utils.writefile(out, { "* F(edit:todo) [[id:e1][Task]]", "** Old value", "TODO", "** New value", "DONE" })
    mobile.encrypt_file(out, stage .. "/mobileorg.org")
    local counts = mobile.pull()
    eq(0, counts.errors)
    eq("* DONE Task", buf_lines(buffer_of(dir .. "/org/a.org"))[2])
    mobile.decrypt_file(stage .. "/mobileorg.org", out)
    eq("", read(out))
  end)

  it("reports a missing staging directory", function()
    dir = setup({ ["a.org"] = { "* A" } })
    config.opts.mobile.directory = dir .. "/missing"
    local okc, err = pcall(mobile.check_setup)
    eq(false, okc)
    eq("Option `mobile.directory' must point to an existing directory", err)
    eq(false, mobile.push())
  end)
end)
