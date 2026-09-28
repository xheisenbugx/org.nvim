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
  --- Keys in the slide buffer, always active.
  keys = {
    next = "<Right>",
    prev = "<Left>",
    first = "<C-c><",
    last = "<C-c>>",
    quit = "<C-c><C-q>",
    toggle_read_only = "<C-c><C-r>",
  },
  --- Keys active only while read-only (they would get in the way of editing).
  read_only_keys = {
    next = { "n", "<Space>" },
    prev = { "p", "<BS>" },
    first = { "gg", "<" },
    last = { "G", ">" },
    quit = { "q", "<Esc>" },
  },
  --- Called with the presentation state when it starts (org-present-mode-hook).
  ---@type fun(state: table)|nil
  on_start = nil,
  --- Called when it ends (org-present-mode-quit-hook).
  ---@type fun(state: table)|nil
  on_quit = nil,
  --- Called with the slide number after each move
  --- (org-present-after-navigate-functions).
  ---@type fun(n: integer, state: table)|nil
  on_slide = nil,
}

M.actions = {
  present_start = { MOD, "start", desc = "Present the buffer as slides (org-present)" },
  present_next = { MOD, "next", desc = "Presentation: next slide" },
  present_prev = { MOD, "prev", desc = "Presentation: previous slide" },
  present_first = { MOD, "first", desc = "Presentation: first slide" },
  present_last = { MOD, "last", desc = "Presentation: last slide" },
  present_toggle_read_only = { MOD, "toggle_read_only", desc = "Presentation: toggle editing the slides" },
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
    data = { source = st.source, slide = st.index, total = #st.slides },
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
  local can_hide_lines = vim.fn.has("nvim-0.11") == 1
  local first_heading = true
  for i, line in ipairs(lines) do
    local row = i - 1
    local stars = line:match("^(%*+%s+)")
    if stars then
      if o.hide_stars then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = #stars, conceal = "" })
      end
      if first_heading and not slide.title then
        first_heading = false
        vim.api.nvim_buf_set_extmark(buf, ns, row, #stars, {
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
        if can_hide_lines then
          vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { conceal_lines = "" })
        else
          vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = #line, conceal = "" })
        end
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
    parts[#parts + 1] = string.format("%d/%d", st.index, #st.slides)
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

--- Write edits of the shown slide back to the source buffer and re-split.
local function sync(st)
  if vim.b[st.buf].changedtick == st.tick or not vim.api.nvim_buf_is_valid(st.source) then
    return
  end
  local slide = st.slides[st.index]
  local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
  vim.api.nvim_buf_set_lines(st.source, slide.first - 1, slide.last, false, lines)
  st.tick = vim.b[st.buf].changedtick
  local src = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)
  st.slides = slides_mod.split(src, st.opts)
  if #st.slides == 0 then
    -- everything was deleted: keep an empty slide so the view stays usable
    st.slides = { { first = 1, last = #src, title = true } }
  end
  st.index = math.max(1, math.min(slides_mod.find(st.slides, slide.first), #st.slides))
end

local function render(st)
  local slide = st.slides[st.index]
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
  if slide then
    decorate(st, slide, lines)
  end
  if vim.api.nvim_win_is_valid(st.win) then
    vim.api.nvim_win_set_cursor(st.win, { 1, 0 })
    vim.api.nvim_win_call(st.win, function()
      vim.fn.winrestview({ topline = 1, topfill = st.opts.padding_top })
    end)
  end
  update_winbar(st)
  show_images(st)
end

local function set_keys(st)
  local config = require("org.config")
  local function map(keys, name)
    local out = {}
    for _, lhs in ipairs(config.lhs_list(keys)) do
      vim.keymap.set("n", lhs, function()
        M[name]()
      end, { buffer = st.buf, nowait = true, desc = "org present: " .. name:gsub("_", " ") })
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
    for name, keys in pairs(st.opts.read_only_keys or {}) do
      vim.list_extend(st.ro_mapped, map(keys, name))
    end
  end
end

local function apply_read_only(st)
  vim.bo[st.buf].modifiable = not st.read_only
  vim.bo[st.buf].readonly = st.read_only
  if vim.api.nvim_win_is_valid(st.win) then
    vim.wo[st.win].concealcursor = st.read_only and "nvic" or "nc"
  end
  if st.opts.hide_cursor and st.read_only then
    vim.o.guicursor = "a:OrgPresentHiddenCursor"
  else
    vim.o.guicursor = st.saved.guicursor
  end
  set_keys(st)
  update_winbar(st)
end

local function goto_slide(n)
  local st = M.state
  if not st then
    return false
  end
  sync(st)
  n = math.max(1, math.min(n, #st.slides))
  st.index = n
  render(st)
  fire("OrgPresentSlide", st.opts.on_slide, st, n, st)
  return true
end

--- Start presenting the current org buffer (org-present), at the slide
--- containing the cursor or at slide `n`.
---@param n? integer
function M.start(n)
  local utils = require("org.utils")
  local source = vim.api.nvim_get_current_buf()
  if M.state then
    if M.state.source == source then
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
    index = index,
    read_only = o.read_only,
    opts = o,
    ro_mapped = {},
    saved = {
      showtabline = vim.o.showtabline,
      laststatus = vim.o.laststatus,
      ruler = vim.o.ruler,
      guicursor = vim.o.guicursor,
    },
  }

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
  vim.b[buf].org_present = true

  vim.o.showtabline = 0
  vim.o.laststatus = 0
  vim.o.ruler = false
  st.win = vim.api.nvim_open_win(buf, true, float_config(o))
  vim.bo[buf].filetype = "org"
  for opt, val in pairs({
    conceallevel = 3,
    foldenable = false,
    wrap = true,
    linebreak = true,
    breakindent = true,
    fillchars = "eob: ",
    winhighlight = "NormalFloat:Normal",
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
      render(st)
      if vim.api.nvim_buf_get_name(st.source) ~= "" then
        vim.api.nvim_buf_call(st.source, function()
          vim.cmd("silent write")
        end)
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
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      if M.state == st and vim.api.nvim_win_is_valid(st.win) then
        vim.api.nvim_win_set_config(st.win, float_config(st.opts))
      end
    end,
  })

  vim.api.nvim_echo({}, false, {})
  fire("OrgPresentStart", o.on_start, st, st)
  fire("OrgPresentSlide", o.on_slide, st, st.index, st)
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
  local st = M.state
  return st ~= nil and goto_slide(st.index + 1)
end

function M.prev()
  local st = M.state
  return st ~= nil and goto_slide(st.index - 1)
end

function M.first()
  return goto_slide(1)
end

function M.last()
  local st = M.state
  return st ~= nil and goto_slide(#st.slides)
end

--- Switch between read-only slides and editing them (org-present-read-only,
--- org-present-read-write).
function M.toggle_read_only()
  local st = M.state
  if not st then
    return false
  end
  if not st.read_only then
    sync(st)
    render(st)
  end
  st.read_only = not st.read_only
  apply_read_only(st)
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
  end
  M.state = nil
  local slide = st.slides[st.index]
  vim.o.showtabline = st.saved.showtabline
  vim.o.laststatus = st.saved.laststatus
  vim.o.ruler = st.saved.ruler
  vim.o.guicursor = st.saved.guicursor
  vim.api.nvim_clear_autocmds({ group = augroup, event = { "WinClosed", "WinEnter", "VimResized" } })
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
