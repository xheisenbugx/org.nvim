local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function setup(present)
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
    extensions = present ~= nil and { present = present } or nil,
  })
end

local slides = require("org.extensions.present.slides")

local DECK = {
  "#+TITLE: My talk",
  "#+AUTHOR: Someone",
  "#+STARTUP: showall",
  "",
  "* First",
  "Intro text with *bold*.",
  "** Detail",
  "More.",
  "* Second",
  "#+begin_src lua",
  ",* not a heading",
  "#+end_src",
  "* Third",
  "The end.",
}

describe("present slides", function()
  it("splits on top-level headlines with a title slide", function()
    local s = slides.split(DECK, {})
    eq(4, #s)
    eq({ first = 1, last = 4, title = true }, s[1])
    eq({ first = 5, last = 8, title = false, level = 1 }, s[2])
    eq({ first = 9, last = 12, title = false, level = 1 }, s[3])
    eq({ first = 13, last = 14, title = false, level = 1 }, s[4])
  end)

  it("splits on deeper headlines with slide_level", function()
    local s = slides.split(DECK, { slide_level = 2 })
    eq(5, #s)
    eq({ 5, 6 }, { s[2].first, s[2].last })
    eq({ 7, 8, 2 }, { s[3].first, s[3].last, s[3].level })
  end)

  it("skips a preamble with nothing to show, or when title_slide is off", function()
    local s = slides.split({ "#+STARTUP: showall", "", "* One", "* Two" }, {})
    eq(2, #s)
    eq(3, s[1].first)
    s = slides.split({ "Preamble text", "* One" }, {})
    eq(true, s[1].title)
    s = slides.split(DECK, { title_slide = false })
    eq(3, #s)
    eq(false, s[1].title)
  end)

  it("keeps hidden keywords in the preamble when hide_keywords is off", function()
    eq(2, #slides.split({ "#+STARTUP: showall", "* One" }, { hide_keywords = false }))
  end)

  it("finds the slide of a line", function()
    local s = slides.split(DECK, {})
    eq(1, slides.find(s, 2))
    eq(2, slides.find(s, 7))
    eq(4, slides.find(s, 14))
    local no_title = slides.split(DECK, { title_slide = false })
    eq(1, slides.find(no_title, 2))
  end)
end)

describe("present", function()
  local present = require("org.extensions.present")
  local events

  local function slide_lines()
    return buf_lines(present.state.buf)
  end

  before_each(function()
    events = {}
    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("OrgPresentSpec", { clear = true }),
      pattern = { "OrgPresentStart", "OrgPresentSlide", "OrgPresentQuit" },
      callback = function(ev)
        events[#events + 1] = { ev.match, ev.data.slide, ev.data.total }
      end,
    })
  end)

  after_each(function()
    present.quit()
    vim.api.nvim_del_augroup_by_name("OrgPresentSpec")
    setup()
  end)

  it("is off unless enabled", function()
    setup()
    eq(nil, require("org.actions").list.present_start)
    setup({})
    ok(require("org.actions").list.present_start)
    ok(require("org.commands").extra.present)
  end)

  it("starts at the slide under the cursor in a new tab, leaving the source alone", function()
    setup({})
    local src = org_buffer(DECK, { 7, 0 })
    local src_win = vim.api.nvim_get_current_win()
    local tabs = #vim.api.nvim_list_tabpages()
    local wo = { number = vim.wo.number, conceallevel = vim.wo.conceallevel, foldenable = vim.wo.foldenable }
    local ls, stal = vim.o.laststatus, vim.o.showtabline
    local tick = vim.b[src].changedtick
    present.start()
    local st = present.state
    ok(st)
    eq(tabs + 1, #vim.api.nvim_list_tabpages())
    eq(st.win, vim.api.nvim_get_current_win())
    eq(2, st.index)
    eq({ "* First", "Intro text with *bold*.", "** Detail", "More." }, slide_lines())
    eq(false, vim.bo[st.buf].modifiable)
    eq(0, vim.o.laststatus)
    eq(0, vim.o.showtabline)
    eq("%=%#OrgPresentCounter#2/4 ", vim.wo[st.win].winbar)
    present.quit()
    eq(nil, present.state)
    eq(tabs, #vim.api.nvim_list_tabpages())
    eq(src_win, vim.api.nvim_get_current_win())
    eq(src, vim.api.nvim_get_current_buf())
    eq(DECK, buf_lines(src))
    eq(tick, vim.b[src].changedtick)
    eq(wo, { number = vim.wo.number, conceallevel = vim.wo.conceallevel, foldenable = vim.wo.foldenable })
    eq({ ls, stal }, { vim.o.laststatus, vim.o.showtabline })
    eq({ 5, 0 }, vim.api.nvim_win_get_cursor(0))
    ok(not vim.api.nvim_buf_is_valid(st.buf))
  end)

  it("moves between slides within bounds", function()
    setup({})
    org_buffer(DECK, { 1, 0 })
    present.start()
    eq(1, present.state.index)
    eq({ "#+TITLE: My talk", "#+AUTHOR: Someone", "#+STARTUP: showall", "" }, slide_lines())
    present.prev()
    eq(1, present.state.index)
    present.next()
    present.next()
    eq({ "* Second", "#+begin_src lua", ",* not a heading", "#+end_src" }, slide_lines())
    present.last()
    eq(4, present.state.index)
    present.next()
    eq(4, present.state.index)
    eq({ "* Third", "The end." }, slide_lines())
    present.first()
    eq(1, present.state.index)
  end)

  it("starts at a given slide with :Org present N", function()
    setup({})
    org_buffer(DECK, { 1, 0 })
    vim.cmd("Org present 3")
    eq(3, present.state.index)
  end)

  it("maps the navigation keys in the slide buffer", function()
    setup({})
    org_buffer(DECK, { 1, 0 })
    present.start()
    vim.api.nvim_feedkeys(vim.keycode("<Right>"), "x", false)
    eq(2, present.state.index)
    vim.api.nvim_feedkeys("n", "x", false)
    eq(3, present.state.index)
    vim.api.nvim_feedkeys(vim.keycode("<BS>"), "x", false)
    eq(2, present.state.index)
    vim.api.nvim_feedkeys("G", "x", false)
    eq(4, present.state.index)
    vim.api.nvim_feedkeys("q", "x", false)
    eq(nil, present.state)
  end)

  it("runs the hooks and User autocmds", function()
    local calls = {}
    setup({
      on_start = function()
        calls[#calls + 1] = "start"
      end,
      on_slide = function(n)
        calls[#calls + 1] = "slide " .. n
      end,
      on_quit = function()
        calls[#calls + 1] = "quit"
      end,
    })
    org_buffer(DECK, { 5, 0 })
    present.start()
    present.next()
    present.quit()
    eq({ "start", "slide 2", "slide 3", "quit" }, calls)
    eq({
      { "OrgPresentStart", 2, 4 },
      { "OrgPresentSlide", 2, 4 },
      { "OrgPresentSlide", 3, 4 },
      { "OrgPresentQuit", 3, 4 },
    }, events)
  end)

  it("hides stars and keywords with extmarks", function()
    setup({})
    org_buffer(DECK, { 1, 0 })
    present.start()
    local function conceals()
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(present.state.buf, -1, 0, -1, { details = true })) do
        local d = m[4]
        if d.conceal or d.conceal_lines then
          out[#out + 1] = { m[2], m[3], d.end_col }
        end
      end
      return out
    end
    -- "#+TITLE: " and "#+AUTHOR: " prefixes, the whole #+STARTUP line
    local c = conceals()
    eq({ 0, 0, 9 }, c[1])
    eq({ 1, 0, 10 }, c[2])
    eq(2, c[3][1])
    present.next()
    eq({ { 0, 0, 2 }, { 2, 0, 3 } }, conceals())
    eq(true, vim.b[present.state.buf].org_hide_emphasis_markers)
  end)

  it("writes slide edits back to the source only after toggling read-only off", function()
    setup({})
    local src = org_buffer(DECK, { 13, 0 })
    present.start()
    local st = present.state
    eq(false, vim.bo[st.buf].modifiable)
    present.toggle_read_only()
    eq(false, st.read_only)
    eq(true, vim.bo[st.buf].modifiable)
    eq("%=%#OrgPresentCounter#[edit] 4/4 ", vim.wo[st.win].winbar)
    -- single-letter keys are for editing now
    eq("", vim.fn.maparg("q", "n", false, false))
    vim.api.nvim_buf_set_lines(st.buf, 1, 2, false, { "The very end.", "* Fourth" })
    present.toggle_read_only()
    eq(true, st.read_only)
    eq(5, #st.slides)
    eq({ "* Third", "The very end." }, slide_lines())
    present.next()
    eq({ "* Fourth" }, slide_lines())
    present.quit()
    eq("The very end.", buf_lines(src)[14])
    eq("* Fourth", buf_lines(src)[15])
  end)

  it("uses the options", function()
    setup({ read_only = false, counter = false, title_slide = false, slide_level = 2 })
    org_buffer(DECK, { 1, 0 })
    present.start()
    eq(1, present.state.index)
    eq({ "* First", "Intro text with *bold*." }, slide_lines())
    eq(true, vim.bo[present.state.buf].modifiable)
    eq("%=%#OrgPresentCounter#[edit] ", vim.wo[present.state.win].winbar)
  end)

  it("cleans up when the slide window is closed", function()
    setup({})
    org_buffer(DECK, { 1, 0 })
    local tabs = #vim.api.nvim_list_tabpages()
    local ls = vim.o.laststatus
    present.start()
    vim.cmd("tabclose")
    vim.wait(100, function()
      return present.state == nil
    end)
    eq(nil, present.state)
    eq(tabs, #vim.api.nvim_list_tabpages())
    eq(ls, vim.o.laststatus)
  end)

  it("resolves relative links against the source file", function()
    setup({})
    local src = org_buffer(DECK, { 1, 0 })
    vim.api.nvim_buf_set_name(src, root .. "/tests/fixtures/present-deck.org")
    present.start()
    eq(root .. "/tests/fixtures", require("org.links").base_dir(present.state.buf))
    eq(root .. "/tests/fixtures/img.png", require("org.links").resolve_path("img.png", present.state.buf))
    present.quit()
    vim.bo[src].modified = false
  end)

  it("refuses a non-org buffer", function()
    setup({})
    vim.cmd("enew!")
    local notify = vim.notify
    local msgs = {}
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    present.start()
    vim.notify = notify
    eq(nil, present.state)
    ok(msgs[1] and msgs[1]:find("not an org buffer", 1, true))
  end)
end)
