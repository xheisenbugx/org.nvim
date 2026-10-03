---@mod org.extensions.present Presentations (org-present)
---
--- Shows an org buffer as a slideshow in a new tab, one top-level subtree per
--- slide, like Emacs org-present. The slides are copies shown in a scratch
--- buffer, so the source buffer, its folds and its options are left alone;
--- with `read_only = false` edits to a slide are written back to the source.
---
--- ```lua
--- require("org").setup({ extensions = { present = { width = 90 } } })
--- ```

local slides_mod = require("org.extensions.present.slides")

local M = {}

local MOD = "org.extensions.present"
local ns = vim.api.nvim_create_namespace("org_present")
local augroup = vim.api.nvim_create_augroup("OrgPresent", { clear = true })

M.defaults = {
  --- Headlines of this level or less start a slide.
  slide_level = 1,
  --- Show the lines before the first headline (#+TITLE, #+AUTHOR, ...) as
  --- a first slide when they have anything to show.
  title_slide = true,
  --- Width of the slide in columns, or a fraction of the screen (0 < w <= 1).
  --- The slide is centered.
  width = 80,
  --- Blank lines above the slide.
  padding_top = 2,
  --- Start read-only; `toggle_read_only` switches to editing, and edits are
  --- written back to the source buffer (org-present-read-only).
  read_only = true,
  --- Hide the cursor while read-only (org-present-hide-cursor). Needs a
  --- terminal or GUI that honours a fully blended cursor.
  hide_cursor = true,
  --- Hide the stars of headlines (org-present-hide-stars-in-headings).
  hide_stars = true,
  --- Hide `#+KEY:` lines other than TITLE, SUBTITLE, AUTHOR, DATE and EMAIL,
  --- and the keyword part of those.
  hide_keywords = true,
  --- Hide emphasis markers (`*bold*` shows as bold) on slides.
  hide_emphasis_markers = true,
  --- Draw a rule under the slide's headline.
  heading_underline = true,
  --- Preview image links on each slide when an image backend is available
  --- (`:h org-images`).
  show_images = true,
  --- Show `3/12` in the window bar.
  counter = true,
  --- Show only a slide's headline at first; <Tab> unfolds it like any
  --- subtree (org-present-startup-folded).
  startup_folded = false,
  --- Indent the headlines below a slide's own headline by two columns per
  --- level (their stars are hidden with `hide_stars`).
  indent_subheadings = true,
  --- Make the terminal font this many points bigger while presenting
  --- (org-present-big, `org-present-text-scale`); 0 leaves it alone. Needs
  --- kitty with remote control (`allow_remote_control` and `listen_on`)
  --- or `font_command`.
  font_scale = 0,
  --- Custom font resizer, `fun(delta)`: delta is `"+N"` to grow by N points
  --- or `"0"` to reset (e.g. for WezTerm or Ghostty via their own IPC).
  ---@type fun(delta: string)|nil
  font_command = nil,
  --- Keys in the slide buffer, always active.
  keys = {
    next = "<Right>",
    prev = "<Left>",
    first = "<C-c><",
    last = "<C-c>>",
    quit = "<C-c><C-q>",
    toggle_read_only = "<C-c><C-r>",
    toggle_one_big_page = "<C-c><C-1>",
    big = "<C-c><C-=>",
    small = "<C-c><C-->",
  },
  --- Keys active only while read-only (they would get in the way of editing).
  read_only_keys = {
    next = { "n", "<Space>" },
    prev = { "p", "<BS>" },
    first = { "gg", "<" },
    last = { "G", ">" },
    quit = { "<Esc>", "q" },
    toggle_one_big_page = "1",
    big = { "+", "=" },
    small = "-",
  },
  --- Called with the presentation state when it starts (org-present-mode-hook).
  ---@type fun(state: table)|nil
  on_start = nil,
  --- Called when it ends (org-present-mode-quit-hook).
  ---@type fun(state: table)|nil
  on_quit = nil,
  --- Called with the slide number, the state and the slide's headline text
  --- after each move (org-present-after-navigate-functions).
  ---@type fun(n: integer, state: table, heading: string)|nil
  on_slide = nil,
}

M.actions = {
  present_start = { MOD, "start", desc = "Present the buffer as slides (org-present)" },
  present_next = { MOD, "next", desc = "Presentation: next slide" },
  present_prev = { MOD, "prev", desc = "Presentation: previous slide" },
  present_first = { MOD, "first", desc = "Presentation: first slide" },
  present_last = { MOD, "last", desc = "Presentation: last slide" },
  present_toggle_read_only = { MOD, "toggle_read_only", desc = "Presentation: toggle editing the slides" },
  present_toggle_one_big_page = {
    MOD,
    "toggle_one_big_page",
    desc = "Presentation: toggle showing the whole file (org-present-toggle-one-big-page)",
  },
  present_big = { MOD, "big", desc = "Presentation: bigger terminal font (org-present-big)" },
  present_small = { MOD, "small", desc = "Presentation: reset the terminal font (org-present-small)" },
  present_quit = { MOD, "quit", desc = "Quit the presentation" },
}

M.commands = {
  present = { MOD, "command", desc = "Present the buffer as slides: :Org present [slide number]" },
}

--- The running presentation, or nil.
---@type table|nil
M.state = nil

local function opts()
  return require("org.extensions").opts("present") or M.defaults
end

local function define_highlights()
  local hl = function(name, val)
    val.default = true
    vim.api.nvim_set_hl(0, name, val)
  end
  hl("OrgPresentHeading", { link = "Title" })
  hl("OrgPresentUnderline", { link = "Title" })
  hl("OrgPresentTitle", { link = "Title" })
  hl("OrgPresentAuthor", { link = "Identifier" })
  hl("OrgPresentDate", { link = "Comment" })
  hl("OrgPresentCounter", { link = "Comment" })
  vim.api.nvim_set_hl(0, "OrgPresentHiddenCursor", { blend = 100, nocombine = true, default = true })
end

function M.setup()
  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = augroup, callback = define_highlights })
end

--- Turned off (or set up again) by a later `setup()`: end the presentation
--- and remove the autocmds.
function M.teardown()
  if M.state then
    M.quit()
  end
  vim.api.nvim_clear_autocmds({ group = augroup })
end

function M.health(h)
  h.ok("present: :Org present in an org buffer")
end

local function fire(event, cb, st, ...)
  if cb then
    local ok, err = pcall(cb, ...)
    if not ok then
      require("org.utils").error("present: " .. event .. " callback failed: " .. tostring(err))
    end
  end
  vim.api.nvim_exec_autocmds("User", {
    pattern = event,
    modeline = false,
    data = { source = st.source, slide = st.index, total = #st.slides, heading = st.heading },
  })
end

local function float_config(o)
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local w = o.width
  if w <= 1 then
    w = math.floor(cols * w)
  end
  w = math.max(20, math.min(cols, w))
  return {
    relative = "editor",
    row = 0,
    col = math.floor((cols - w) / 2),
    width = w,
    height = math.max(1, rows),
    style = "minimal",
    zindex = 40,
  }
end

--- Conceal and highlight the slide in the buffer.
local function decorate(st, slide, lines)
  local o = st.opts
  local buf = st.buf
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local width = vim.api.nvim_win_is_valid(st.win) and vim.api.nvim_win_get_width(st.win) or 80
  local first_heading = true
  -- level of the slide headline above (for indenting deeper headlines)
  local base
  local todo_cfg = require("org.files").get_buffer(buf).settings.todo
  for i, line in ipairs(lines) do
    local row = i - 1
    local stars = line:match("^(%*+%s+)")
    if stars then
      local level = #line:match("^%*+")
      if o.hide_stars then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = #stars, conceal = "" })
      end
      local is_head
      if slide.all then
        is_head = level <= o.slide_level
      else
        is_head = first_heading and not slide.title
      end
      if not is_head and o.hide_stars and o.indent_subheadings and base and level > base then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
          virt_text = { { string.rep("  ", level - base), "Normal" } },
          virt_text_pos = "inline",
        })
      end
      if is_head then
        first_heading = false
        base = level
        -- the TODO keyword keeps its own colour
        local start = #stars
        local parts = require("org.parser").parse_headline_line(line, todo_cfg)
        if parts and parts.todo then
          start = line:find(parts.todo, #stars + 1, true) + #parts.todo
        end
        vim.api.nvim_buf_set_extmark(buf, ns, row, start, {
          end_col = #line,
          hl_group = "OrgPresentHeading",
          priority = 150,
        })
        if o.heading_underline then
          local text = vim.fn.strdisplaywidth(line) - (o.hide_stars and #stars or 0)
          vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
            virt_lines = { { { string.rep("━", math.max(1, math.min(text, width))), "OrgPresentUnderline" } } },
          })
        end
      end
    elseif o.hide_keywords then
      local key = slides_mod.keyword(line)
      if key and slides_mod.shown_keywords[key] then
        local prefix = #line:match("^%s*#%+[%w_%-]+:%s*")
        local group = key == "author" and "OrgPresentAuthor"
          or (key == "date" or key == "email") and "OrgPresentDate"
          or "OrgPresentTitle"
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = prefix, conceal = "" })
        vim.api.nvim_buf_set_extmark(buf, ns, row, prefix, { end_col = #line, hl_group = group, priority = 150 })
      elseif key then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { conceal_lines = "" })
      end
    end
  end
  if o.padding_top > 0 and #lines > 0 then
    local pad = {}
    for _ = 1, o.padding_top do
      pad[#pad + 1] = { { "", "Normal" } }
    end
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_lines = pad, virt_lines_above = true })
  end
end

local function update_winbar(st)
  if not vim.api.nvim_win_is_valid(st.win) then
    return
  end
  local parts = {}
  if not st.read_only then
    parts[#parts + 1] = "[edit]"
  end
  if st.opts.counter then
    parts[#parts + 1] = st.big and string.format("all %d", #st.slides) or string.format("%d/%d", st.index, #st.slides)
  end
  vim.wo[st.win].winbar = #parts > 0 and ("%=%#OrgPresentCounter#" .. table.concat(parts, " ") .. " ") or ""
end

local function show_images(st)
  if not st.opts.show_images then
    return
  end
  local ok, images = pcall(require, "org.ui.images")
  if ok and images.backend() then
    pcall(images.show_links, st.buf, 1, vim.api.nvim_buf_line_count(st.buf))
  end
end

--- The slide shown: one of `st.slides`, or the whole file in one-big-page
--- mode.
local function shown_slide(st)
  if st.big then
    return { first = 1, last = vim.api.nvim_buf_line_count(st.source), title = false, all = true }
  end
  return st.slides[st.index]
end

--- Split the source into slides again.
local function resplit(st)
  local src = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)
  st.slides = slides_mod.split(src, st.opts)
  if #st.slides == 0 then
    -- everything was deleted: keep an empty slide so the view stays usable
    st.slides = { { first = 1, last = #src, title = true } }
  end
  st.src_tick = vim.b[st.source].changedtick
  return src
end

--- When the source changed outside the presentation, split it again and
--- find the slide shown (by its first line, nearest to where it was).
--- Returns false when the slide shown can't be found.
local function refresh(st)
  if vim.b[st.source].changedtick == st.src_tick then
    return true
  end
  local src = resplit(st)
  if st.big then
    return false
  end
  local best, dist
  for i, s in ipairs(st.slides) do
    if st.shown and src[s.first] == st.shown.head then
      local d = math.abs(s.first - st.shown.first)
      if not dist or d < dist then
        best, dist = i, d
      end
    end
  end
  st.index = best or math.max(1, math.min(st.index, #st.slides))
  return best ~= nil
end

--- Write edits of the shown slide back to the source buffer and re-split.
local function sync(st)
  if not vim.api.nvim_buf_is_loaded(st.source) then
    return
  end
  local edited = vim.api.nvim_buf_is_valid(st.buf) and vim.b[st.buf].changedtick ~= st.tick
  local found = refresh(st)
  if not edited then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
  st.tick = vim.b[st.buf].changedtick
  if not found then
    -- the lines the slide came from moved or went away: don't guess
    vim.fn.setreg('"', lines, "l")
    require("org.utils").warn('present: the file changed while the slide was edited; its text is in register "')
    return
  end
  local slide = shown_slide(st)
  vim.api.nvim_buf_set_lines(st.source, slide.first - 1, slide.last, false, lines)
  resplit(st)
  if not st.big then
    st.index = math.max(1, math.min(slides_mod.find(st.slides, slide.first), #st.slides))
  end
end

--- The text org-present passes to its navigation hook: the slide's headline
--- (the title on the title slide).
local function heading_text(slide, lines)
  if slide.all then
    return ""
  end
  if slide.title then
    for _, l in ipairs(lines) do
      local key, value = slides_mod.keyword(l)
      if key == "title" then
        return value
      end
    end
    return ""
  end
  return ((lines[1] or ""):gsub("^%*+%s+", ""):gsub("%s+$", ""))
end

--- Show the current slide; the cursor goes to line `lnum` (default 1).
local function render(st, lnum)
  refresh(st)
  local slide = shown_slide(st)
  local lines = {}
  if slide then
    lines = vim.api.nvim_buf_get_lines(st.source, slide.first - 1, slide.last, false)
  end
  local ok, images = pcall(require, "org.ui.images")
  if ok then
    pcall(images.clear, st.buf)
  end
  local buf = st.buf
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  local ul = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = ul
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = not st.read_only
  vim.bo[buf].readonly = st.read_only
  st.tick = vim.b[buf].changedtick
  st.shown = slide and { first = slide.first, head = lines[1] } or nil
  st.heading = slide and heading_text(slide, lines) or ""
  vim.b[buf].org_present_base = slide and slide.level or st.opts.slide_level
  if slide then
    decorate(st, slide, lines)
  end
  if vim.api.nvim_win_is_valid(st.win) then
    lnum = math.max(1, math.min(lnum or 1, #lines))
    local folded = st.opts.startup_folded and not st.big
    vim.wo[st.win].foldenable = folded
    vim.api.nvim_win_set_cursor(st.win, { lnum, 0 })
    vim.api.nvim_win_call(st.win, function()
      if folded then
        vim.cmd("normal! zM")
      end
      if lnum == 1 then
        vim.fn.winrestview({ topline = 1, topfill = st.opts.padding_top })
      else
        vim.cmd("normal! zt")
      end
    end)
  end
  update_winbar(st)
  show_images(st)
end

local function set_keys(st)
  local config = require("org.config")
  -- keys that a presentation key may start: global Normal-mode keys, the
  -- leaders and the presentation's own keys. A key that starts one waits
  -- for it (<Space> with a space leader); the others are nowait.
  local longer = {}
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    longer[#longer + 1] = vim.keycode(m.lhs)
  end
  for _, leader in ipairs({ vim.g.mapleader or "\\", vim.g.maplocalleader or "\\" }) do
    longer[#longer + 1] = vim.keycode(leader) .. "x"
  end
  for _, set in ipairs({ st.opts.keys or {}, st.read_only and st.opts.read_only_keys or {} }) do
    for _, keys in pairs(set) do
      for _, lhs in ipairs(config.lhs_list(keys)) do
        longer[#longer + 1] = vim.keycode(lhs)
      end
    end
  end
  local function waits(lhs)
    local kc = vim.keycode(lhs)
    for _, other in ipairs(longer) do
      if #other > #kc and other:sub(1, #kc) == kc then
        return true
      end
    end
    return false
  end
  local function map(keys, name)
    local out = {}
    for _, lhs in ipairs(config.lhs_list(keys)) do
      vim.keymap.set("n", lhs, function()
        M[name]()
      end, { buffer = st.buf, nowait = not waits(lhs), desc = "org present: " .. name:gsub("_", " ") })
      out[#out + 1] = lhs
    end
    return out
  end
  for name, keys in pairs(st.opts.keys or {}) do
    map(keys, name)
  end
  for _, lhs in ipairs(st.ro_mapped) do
    pcall(vim.keymap.del, "n", lhs, { buffer = st.buf })
  end
  st.ro_mapped = {}
  if st.read_only then
    local views = require("org.extensions.views_util")
    for name in pairs(st.opts.read_only_keys or {}) do
      vim.list_extend(st.ro_mapped, map(views.lhs(st.opts.read_only_keys, name, st.opts.keys), name))
    end
  end
end

-- Global options a presentation changes. They are set only while its tab
-- is the current one.
local GLOBALS = { "showtabline", "laststatus", "ruler", "guicursor" }

-- 'guicursor' entry hiding the cursor in the modes used on a read-only slide
local HIDDEN_CURSOR = "n-v-ve-o:block-OrgPresentHiddenCursor"

local function save_globals(st)
  st.saved = {}
  for _, name in ipairs(GLOBALS) do
    st.saved[name] = vim.o[name]
  end
end

local function restore_globals(st)
  for _, name in ipairs(GLOBALS) do
    vim.o[name] = st.saved[name]
  end
end

local function apply_globals(st)
  vim.o.showtabline = 0
  vim.o.laststatus = 0
  vim.o.ruler = false
  if st.opts.hide_cursor and st.read_only then
    -- on the slide only: the command line and Insert mode keep their cursor
    local saved = st.saved.guicursor
    vim.o.guicursor = (saved ~= "" and saved .. "," or "") .. HIDDEN_CURSOR
  else
    vim.o.guicursor = st.saved.guicursor
  end
end

local function in_tab(st)
  return vim.api.nvim_get_current_tabpage() == st.tab
end

local function apply_read_only(st)
  vim.bo[st.buf].modifiable = not st.read_only
  vim.bo[st.buf].readonly = st.read_only
  if vim.api.nvim_win_is_valid(st.win) then
    vim.wo[st.win].concealcursor = st.read_only and "nvic" or "nc"
  end
  if in_tab(st) then
    apply_globals(st)
  end
  set_keys(st)
  update_winbar(st)
end

--- Change the terminal font: `delta` is "+N" or "0" (reset). Returns false
--- when there is no way to do it here.
local function set_font(st, delta)
  local utils = require("org.utils")
  if st.opts.font_command then
    local ok, err = pcall(st.opts.font_command, delta)
    if not ok then
      utils.error("present: font_command failed: " .. tostring(err))
    end
    return true
  end
  if vim.env.KITTY_WINDOW_ID and vim.fn.executable("kitty") == 1 then
    local cmd = { "kitty", "@" }
    if vim.env.KITTY_LISTEN_ON then
      vim.list_extend(cmd, { "--to", vim.env.KITTY_LISTEN_ON })
    end
    vim.list_extend(cmd, { "set-font-size", "--", delta })
    vim.system(cmd, { text = true }, function(res)
      if res.code ~= 0 then
        vim.schedule(function()
          utils.warn("present: kitty @ set-font-size failed: " .. vim.trim(res.stderr or ""))
        end)
      end
    end)
    return true
  end
  return false
end

--- The source buffer was unloaded or wiped out: end the presentation, and
--- keep unwritten slide edits in the unnamed register.
local function source_gone(st)
  if M.state ~= st or vim.api.nvim_buf_is_loaded(st.source) then
    -- ended already, or reloaded (:edit!)
    return
  end
  if vim.api.nvim_buf_is_valid(st.buf) and vim.b[st.buf].changedtick ~= st.tick then
    vim.fn.setreg('"', vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), "l")
    require("org.utils").warn('present: the presented buffer was closed; its edits are in register "')
  end
  M.quit()
end

--- The running presentation. When its source buffer is gone it ends
--- here, and the second value is true (the action did something).
---@return table|nil st
---@return boolean ended
local function current()
  local st = M.state
  if st and not vim.api.nvim_buf_is_loaded(st.source) then
    source_gone(st)
    return nil, true
  end
  return st, false
end

local function goto_slide(n)
  local st, ended = current()
  if not st then
    return ended
  end
  sync(st)
  st.big = false
  n = math.max(1, math.min(n, #st.slides))
  st.index = n
  render(st)
  fire("OrgPresentSlide", st.opts.on_slide, st, n, st, st.heading)
  return true
end

--- Leave one-big-page mode for the slide under the cursor.
local function leave_big(st)
  if not st.big then
    return
  end
  sync(st)
  local lnum = vim.api.nvim_win_is_valid(st.win) and vim.api.nvim_win_get_cursor(st.win)[1] or 1
  st.big = false
  st.index = slides_mod.find(st.slides, lnum)
end

--- Start presenting the current org buffer (org-present), at the slide
--- containing the cursor or at slide `n`.
---@param n? integer
function M.start(n)
  local utils = require("org.utils")
  local source = vim.api.nvim_get_current_buf()
  if M.state then
    if M.state.source == source or M.state.buf == source then
      if n then
        goto_slide(n)
      end
      return M.focus()
    end
    M.quit()
  end
  if vim.bo[source].filetype ~= "org" then
    utils.error("present: not an org buffer")
    return
  end
  local o = vim.deepcopy(opts())
  local src_lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
  local slides = slides_mod.split(src_lines, o)
  if #slides == 0 then
    utils.warn("present: nothing to present")
    return
  end
  local source_win = vim.api.nvim_get_current_win()
  local index = n and math.max(1, math.min(n, #slides))
    or slides_mod.find(slides, vim.api.nvim_win_get_cursor(source_win)[1])

  local st = {
    source = source,
    source_win = source_win,
    slides = slides,
    src_tick = vim.b[source].changedtick,
    index = index,
    read_only = o.read_only,
    big = false,
    opts = o,
    ro_mapped = {},
  }
  save_globals(st)

  vim.cmd("tab split")
  st.tab = vim.api.nvim_get_current_tabpage()
  st.bg_win = vim.api.nvim_get_current_win()
  st.bg_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[st.bg_buf].bufhidden = "wipe"
  vim.api.nvim_win_set_buf(st.bg_win, st.bg_buf)
  for opt, val in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    cursorline = false,
    statuscolumn = "",
    winbar = "",
    fillchars = "eob: ",
  }) do
    vim.wo[st.bg_win][opt] = val
  end

  local buf = vim.api.nvim_create_buf(false, true)
  st.buf = buf
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local src_name = vim.api.nvim_buf_get_name(source)
  vim.api.nvim_buf_set_name(buf, "org-present://" .. (src_name ~= "" and src_name or tostring(source)))
  vim.b[buf].org_hide_emphasis_markers = o.hide_emphasis_markers
  vim.b[buf].org_base_dir = src_name ~= "" and vim.fn.fnamemodify(src_name, ":p:h") or nil
  vim.b[buf].org_settings_source = source
  if o.hide_stars then
    -- the stars are concealed: bullets or star overlays would cover the text
    vim.b[buf].org_ui = { bullets = false, hide_leading_stars = false, indent_mode = false }
  end
  vim.b[buf].org_present = true

  apply_globals(st)
  st.win = vim.api.nvim_open_win(buf, true, float_config(o))
  vim.bo[buf].filetype = "org"
  for opt, val in pairs({
    conceallevel = 3,
    foldenable = false,
    wrap = true,
    linebreak = true,
    breakindent = true,
    fillchars = "eob: ,fold: ",
    -- empty, like org windows: a closed slide headline is drawn as it is
    -- open (concealed stars and links, its TODO face), with org's ellipsis
    foldtext = "",
    winhighlight = "NormalFloat:Normal,WinBar:Normal,WinBarNC:Normal",
  }) do
    vim.wo[st.win][opt] = val
  end

  M.state = st
  render(st)
  apply_read_only(st)

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = augroup,
    buffer = buf,
    callback = function()
      sync(st)
      render(st, vim.api.nvim_win_get_cursor(st.win)[1])
      -- autocommands don't nest in BufWriteCmd: save_buffer runs the
      -- write hooks (crypt, transclusion, ...)
      if vim.api.nvim_buf_get_name(st.source) ~= "" then
        require("org.utils").save_buffer_or_warn(st.source)
      end
    end,
  })
  vim.api.nvim_create_autocmd("QuitPre", {
    group = augroup,
    buffer = buf,
    callback = function()
      -- :q keeps the edits: they go to the source buffer (still unsaved)
      if M.state == st then
        sync(st)
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].modified = false
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = { tostring(st.win), tostring(st.bg_win) },
    callback = function()
      if M.state == st and not st.closing then
        vim.schedule(M.quit)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    callback = function()
      if M.state == st and vim.api.nvim_get_current_win() == st.bg_win and vim.api.nvim_win_is_valid(st.win) then
        vim.api.nvim_set_current_win(st.win)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabLeave", {
    group = augroup,
    callback = function()
      if M.state == st and in_tab(st) then
        restore_globals(st)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = augroup,
    callback = function()
      if M.state == st and in_tab(st) then
        save_globals(st)
        apply_globals(st)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = augroup,
    buffer = source,
    callback = function()
      vim.schedule(function()
        source_gone(st)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      if M.state == st and vim.api.nvim_win_is_valid(st.win) then
        vim.api.nvim_win_set_config(st.win, float_config(st.opts))
        local slide = shown_slide(st)
        if slide then
          decorate(st, slide, vim.api.nvim_buf_get_lines(st.buf, 0, -1, false))
        end
      end
    end,
  })

  if o.font_scale > 0 then
    st.font_big = set_font(st, "+" .. o.font_scale)
  end
  vim.api.nvim_echo({}, false, {})
  fire("OrgPresentStart", o.on_start, st, st)
  fire("OrgPresentSlide", o.on_slide, st, st.index, st, st.heading)
end

--- `:Org present [n]`.
---@param arg? string
function M.command(arg)
  M.start(tonumber(arg or ""))
end

--- Move the cursor back into the presentation.
function M.focus()
  local st = M.state
  if st and vim.api.nvim_win_is_valid(st.win) then
    vim.api.nvim_set_current_win(st.win)
    return true
  end
  return false
end

function M.next()
  local st, ended = current()
  if not st then
    return ended
  end
  sync(st)
  leave_big(st)
  return goto_slide(st.index + 1)
end

function M.prev()
  local st, ended = current()
  if not st then
    return ended
  end
  sync(st)
  leave_big(st)
  return goto_slide(st.index - 1)
end

function M.first()
  return goto_slide(1)
end

function M.last()
  local st, ended = current()
  if not st then
    return ended
  end
  sync(st)
  return goto_slide(#st.slides)
end

--- Switch between read-only slides and editing them (org-present-read-only,
--- org-present-read-write).
function M.toggle_read_only()
  local st, ended = current()
  if not st then
    return ended
  end
  if not st.read_only then
    sync(st)
    render(st, vim.api.nvim_win_get_cursor(st.win)[1])
  end
  st.read_only = not st.read_only
  apply_read_only(st)
  return true
end

--- Show the whole file, or go back to the slide under the cursor
--- (org-present-toggle-one-big-page).
function M.toggle_one_big_page()
  local st, ended = current()
  if not st then
    return ended
  end
  if st.big then
    leave_big(st)
    render(st)
    fire("OrgPresentSlide", st.opts.on_slide, st, st.index, st, st.heading)
  else
    sync(st)
    local first = st.slides[st.index].first
    st.big = true
    render(st, first)
  end
  return true
end

--- Make the terminal font bigger (org-present-big): by `font_scale` points,
--- 4 when that is 0.
function M.big()
  local st = M.state
  if not st then
    return false
  end
  if not st.font_big then
    local step = st.opts.font_scale > 0 and st.opts.font_scale or 4
    st.font_big = set_font(st, "+" .. step)
    if not st.font_big then
      require("org.utils").warn("present: can't change the font here (see font_command in :h org-extensions-present)")
    end
  end
  return true
end

--- Reset the terminal font (org-present-small).
function M.small()
  local st = M.state
  if not st then
    return false
  end
  if st.font_big then
    set_font(st, "0")
    st.font_big = false
  end
  return true
end

--- End the presentation (org-present-quit): write back edits, close the tab,
--- restore the options and put the source cursor on the slide shown last.
function M.quit()
  local st = M.state
  if not st then
    return false
  end
  st.closing = true
  if vim.api.nvim_buf_is_valid(st.buf) then
    pcall(sync, st)
    pcall(leave_big, st)
  end
  M.state = nil
  local slide = not st.big and st.slides[st.index] or nil
  if in_tab(st) then
    restore_globals(st)
  end
  if st.font_big then
    set_font(st, "0")
  end
  vim.api.nvim_clear_autocmds({
    group = augroup,
    event = { "WinClosed", "WinEnter", "VimResized", "TabEnter", "TabLeave", "BufUnload" },
  })
  if vim.api.nvim_tabpage_is_valid(st.tab) then
    if #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(st.tab))
    end
  end
  for _, b in ipairs({ st.buf, st.bg_buf }) do
    if vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  if vim.api.nvim_win_is_valid(st.source_win) then
    vim.api.nvim_set_current_win(st.source_win)
    if slide and vim.api.nvim_win_get_buf(st.source_win) == st.source then
      local lnum = math.min(slide.first, vim.api.nvim_buf_line_count(st.source))
      vim.api.nvim_win_set_cursor(st.source_win, { lnum, 0 })
    end
  end
  fire("OrgPresentQuit", st.opts.on_quit, st, st)
  return true
end

return M
