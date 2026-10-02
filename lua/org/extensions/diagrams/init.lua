---@mod org.extensions.diagrams Diagram source blocks (mermaid, dot, plantuml)
---
--- Babel languages `mermaid` (ob-mermaid, mmdc) and `dot` (ob-dot,
--- Graphviz), and extras for the core `plantuml` port: executing a block
--- writes the diagram to its `:file` (or a generated name), results are
--- cached by content hash, the result link is previewed inline when an
--- image backend is available, and diagrams can be rendered on save.

local MOD = "org.extensions.diagrams"

local M = {}

M.defaults = {
  --- Languages handled by the extension (any of "mermaid", "dot", "plantuml").
  languages = { "mermaid", "dot", "plantuml" },
  --- mmdc: `command` (a string run by the shell, or a list of words),
  --- extra `args`, and defaults for :theme, :background-color,
  --- :mermaid-config-file and :puppeteer-config-file.
  mermaid = { command = "mmdc", args = {}, theme = nil, background = nil, config_file = nil, puppeteer_config = nil },
  --- Graphviz: `command` (:cmd overrides it per block) and extra `args`.
  dot = { command = "dot", args = {} },
  --- A block without `:file` gets `output_dir/LANG-HASH8.FORMAT`
  --- (relative to the org file's directory, or :dir).
  auto_file = true,
  output_dir = "diagrams",
  format = "png",
  --- Keep rendered diagrams in `cache_dir`, keyed by a hash of the
  --- language, command and body, and copy them instead of rendering again.
  cache = true,
  cache_dir = vim.fn.stdpath("cache") .. "/org/diagrams",
  --- Preview the result image inline after a diagram block runs (needs an
  --- image backend, see :h org-images).
  auto_preview = true,
  --- Render every diagram block of an org buffer after it is written, in
  --- the background; the results are saved when nothing else changed.
  render_on_save = false,
  --- Cache pruning (at startup): drop entries unused for this many days,
  --- then the least recently used ones beyond this many megabytes (nil or
  --- false: no limit).
  cache_max_age = 90,
  cache_max_size = 200,
}

M.actions = {
  diagrams_render = { MOD, "render", desc = "Render the diagram block at point" },
  diagrams_rerender = { MOD, "rerender", desc = "Render the diagram block at point, ignoring the cache" },
  diagrams_render_buffer = { MOD, "render_buffer", desc = "Render every diagram block of the buffer" },
  diagrams_clear_cache = { MOD, "clear_cache", desc = "Delete the rendered-diagram cache" },
  diagrams_clean = { MOD, "clean", desc = "Delete generated diagrams no org file of this directory links to" },
}

M.commands = {
  diagrams_clean = {
    MOD,
    "clean_command",
    desc = "Delete unreferenced generated diagrams: :Org diagrams_clean [dry]",
    complete = function()
      return { "dry" }
    end,
  },
}

local function opts()
  return require("org.extensions").opts("diagrams") or M.defaults
end

local function langs()
  local set = {}
  for _, l in ipairs(opts().languages or {}) do
    set[l] = true
  end
  return set
end

-- what setup replaced, restored by teardown
local saved = nil
local group = nil

local DEFAULT_HEADER_ARGS = { results = "file", exports = "results" }

---------------------------------------------------------------------------
-- Rendering blocks
---------------------------------------------------------------------------

--- The diagram block at (bufnr, lnum), or nil.
local function block_at(bufnr, lnum)
  local b = require("org.babel").at_block(bufnr, lnum)
  if b and not b.call and langs()[b.lang] then
    return b
  end
  return nil
end

--- Render the diagram block at the cursor (C-c C-c on it does the same).
--- Returns false when the cursor is not on a diagram block.
function M.render(o)
  o = o or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local b = block_at(bufnr, lnum)
  if not b then
    return false
  end
  require("org.babel").execute({ bufnr = bufnr, lnum = b.start, sync = o.sync, on_done = o.on_done })
end

--- Render the block at point without using the cache.
function M.rerender(o)
  local render = require("org.extensions.diagrams.render")
  o = vim.tbl_extend("force", {}, o or {})
  local on_done = o.on_done
  -- cleared again when the block failed before reaching the cache
  o.on_done = function(...)
    render.skip_cache = nil
    if on_done then
      on_done(...)
    end
  end
  render.skip_cache = true
  local ret = M.render(o)
  if ret == false then
    render.skip_cache = nil
  end
  return ret
end

--- Diagram blocks of `bufnr` that may run without asking (no `:eval no`,
--- `never` or `query`), last first so running one doesn't move the others.
local function runnable_blocks(bufnr)
  local babel = require("org.babel")
  local blocks = require("org.babel.blocks")
  local set = langs()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local file = babel.get_file(bufnr)
  local out = {}
  for _, b in ipairs(blocks.parse_blocks(lines)) do
    if not b.call and set[b.lang] then
      local args = babel.block_args(b, file, bufnr)
      local ev = args.eval or (args.noeval and "no")
      if ev ~= "no" and ev ~= "never" and ev ~= "query" then
        table.insert(out, 1, b)
      end
    end
  end
  return out
end

--- Render every diagram block of `bufnr` (synchronously, last block
--- first). Unchanged diagrams come from the cache. Returns the count.
function M.render_buffer(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if vim.bo[bufnr].filetype ~= "org" then
    return false
  end
  local babel = require("org.babel")
  local n = 0
  for _, b in ipairs(runnable_blocks(bufnr)) do
    babel.execute({ bufnr = bufnr, lnum = b.start, skip_confirm = true, sync = true })
    n = n + 1
  end
  return n
end

-- buffers being rendered after a save (and whether another save came in
-- meanwhile); buffers being written by us
local rendering, saving = {}, {}

-- The buffer's text without the #+RESULTS sections (and blank lines,
-- which results bring along): equal before and after the renders when
-- only results changed.
local function without_results(bufnr)
  local out, skip = {}, false
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:match("^%s*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss]") then
      skip = true
    elseif not l:find("%S") then
      skip = false
    elseif not skip then
      out[#out + 1] = l
    end
  end
  return table.concat(out, "\n")
end

--- `render_on_save`: after `bufnr` was written, render its diagram blocks
--- one after the other in the background (Neovim stays responsive while
--- mmdc or dot run; unchanged diagrams come from the cache). When the
--- results changed the buffer and nothing else did meanwhile, it is
--- written again; after your own edits it is left modified. Calls
--- `on_done(n)` with the number of blocks run.
---@param bufnr integer
---@param on_done? fun(n: integer)
function M.render_after_save(bufnr, on_done)
  if rendering[bufnr] then
    rendering[bufnr].again = true
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  local blocks = runnable_blocks(bufnr)
  if #blocks == 0 then
    if on_done then
      on_done(0)
    end
    return
  end
  local babel = require("org.babel")
  local state = { again = false }
  rendering[bufnr] = state
  local before = without_results(bufnr)
  local i = 0
  local function finish()
    rendering[bufnr] = nil
    local valid = vim.api.nvim_buf_is_valid(bufnr)
    -- written again only when nothing but results changed
    if valid and vim.bo[bufnr].modified and without_results(bufnr) == before then
      saving[bufnr] = true
      pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent write")
      end)
      saving[bufnr] = nil
    end
    if on_done then
      on_done(i)
    end
    if state.again then
      M.render_after_save(bufnr)
    end
  end
  local function nxt()
    i = i + 1
    local b = blocks[i]
    if not b or not vim.api.nvim_buf_is_valid(bufnr) then
      i = i - 1
      return finish()
    end
    -- go on once the block is done (or failed, or never answers)
    local went = false
    local function go()
      if not went then
        went = true
        vim.schedule(nxt)
      end
    end
    local timeout = tonumber(require("org.config").opts.babel.timeout) or 0
    vim.defer_fn(go, (timeout > 0 and timeout or 120000) + 1000)
    local ok = pcall(babel.execute, { bufnr = bufnr, lnum = b.start, skip_confirm = true, on_done = go })
    if not ok then
      go()
    end
  end
  nxt()
end

--- Is `name` a cache entry (render.cache_path: a sha256 and an optional
--- extension)? Other files in `cache_dir` are never deleted: it may be
--- set to a directory that holds more than the cache.
local function cache_entry(name)
  return name:match("^" .. string.rep("%x", 64) .. "%.?[%w]*$") ~= nil
end

--- Delete the cached diagrams.
function M.clear_cache()
  local dir = require("org.utils").expand(opts().cache_dir)
  local n = 0
  for _, f in ipairs(vim.fn.glob(dir .. "/*", true, true)) do
    if cache_entry(vim.fn.fnamemodify(f, ":t")) and vim.fn.delete(f) == 0 then
      n = n + 1
    end
  end
  require("org.utils").notify(string.format("diagrams: removed %d cached file(s)", n))
  return n
end

--- Prune the cache: files unused for `max_age` days, then the least
--- recently used beyond `max_size` megabytes. Returns the count removed.
---@param max_age? number|false days (default: the `cache_max_age` option)
---@param max_size? number|false megabytes (default: `cache_max_size`)
function M.prune_cache(max_age, max_size)
  local o = opts()
  if max_age == nil then
    max_age = o.cache_max_age
  end
  if max_size == nil then
    max_size = o.cache_max_size
  end
  local dir = require("org.utils").expand(o.cache_dir)
  local entries = {}
  local handle = vim.uv.fs_scandir(dir)
  while handle do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" and cache_entry(name) then
      local path = dir .. "/" .. name
      local st = vim.uv.fs_stat(path)
      if st then
        entries[#entries + 1] = { path = path, time = st.mtime.sec, size = st.size }
      end
    end
  end
  table.sort(entries, function(a, b)
    return a.time > b.time
  end)
  local n, total = 0, 0
  local now = os.time()
  for _, e in ipairs(entries) do
    local old = tonumber(max_age) and now - e.time > max_age * 86400
    local big = tonumber(max_size) and total + e.size > max_size * 1024 * 1024
    if old or big then
      if os.remove(e.path) then
        n = n + 1
      end
    else
      total = total + e.size
    end
  end
  return n
end

-- A generated file name: LANG-HASH8.EXT
local GENERATED = { mermaid = true, dot = true, plantuml = true }
local function generated(name)
  local lang = name:match("^(%a+)%-%x%x%x%x%x%x%x%x%.[%w]+$")
  return lang and GENERATED[lang] or false
end

--- Generated diagrams (`output_dir/LANG-HASH8.EXT`) of the directory of
--- `bufnr`'s file that none of the org files there links to or names in
--- `:file`: `{ path }`, and the directory.
---@param bufnr? integer
---@return string[] unused, string|nil dir
function M.unreferenced(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then
    return {}, nil
  end
  local base = vim.fn.fnamemodify(file, ":p:h")
  local out_dir = opts().output_dir or ""
  local dir = out_dir ~= "" and require("org.utils").expand(out_dir, base) or base
  if not require("org.utils").is_absolute(dir) then
    dir = base .. "/" .. dir
  end
  if vim.fn.isdirectory(dir) == 0 then
    return {}, dir
  end
  -- every org file of the directory may use the same output_dir: the
  -- names they mention (buffers win over the files on disk)
  local text, seen = {}, {}
  -- loaded buffers of the directory (unsaved text counts), this one too
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if vim.api.nvim_buf_is_loaded(b) and (b == bufnr or vim.fn.fnamemodify(name, ":p:h") == base) then
      if b == bufnr or name:match("%.org$") or name:match("%.org_archive$") then
        seen[vim.fn.fnamemodify(name, ":p")] = true
        text[#text + 1] = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
      end
    end
  end
  for _, f in ipairs(vim.fn.glob(base .. "/*.org", true, true)) do
    if not seen[vim.fn.fnamemodify(f, ":p")] then
      local fh = io.open(f, "rb")
      if fh then
        text[#text + 1] = fh:read("*a")
        fh:close()
      end
    end
  end
  local all = table.concat(text, "\n")
  local unused = {}
  for _, name in ipairs(vim.fn.readdir(dir)) do
    if generated(name) and not all:find(name, 1, true) then
      unused[#unused + 1] = dir .. "/" .. name
    end
  end
  table.sort(unused)
  return unused, dir
end

--- Delete the generated diagrams of the current file's directory that no
--- org file there refers to (asks first). With `dry`, only list them.
---@param dry? boolean
function M.clean(dry)
  local utils = require("org.utils")
  local unused, dir = M.unreferenced(0)
  if #unused == 0 then
    utils.notify("diagrams: no unused diagrams" .. (dir and (" in " .. require("org.utils").abbreviate(dir)) or ""))
    return 0
  end
  local names = vim.tbl_map(function(p)
    return vim.fn.fnamemodify(p, ":t")
  end, unused)
  if dry == true then
    utils.notify("diagrams: unused in " .. require("org.utils").abbreviate(dir) .. ": " .. table.concat(names, ", "))
    return #unused
  end
  local choice = utils.select({ "Yes", "No" }, {
    prompt = string.format("Delete %d unused diagram(s) in %s?", #unused, require("org.utils").abbreviate(dir)),
  })
  if choice ~= "Yes" then
    return 0
  end
  local n = 0
  for _, p in ipairs(unused) do
    if os.remove(p) then
      n = n + 1
    end
  end
  utils.notify(string.format("diagrams: removed %d unused diagram(s)", n))
  return n
end

--- `:Org diagrams_clean [dry]`.
function M.clean_command(args)
  return M.clean(vim.trim(args or "") == "dry")
end

---------------------------------------------------------------------------
-- Preview after execution
---------------------------------------------------------------------------

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, gif = true, svg = true, webp = true }

--- Show the image of a diagram's result link (`[[file:RESULT]]`) inline.
function M.preview(bufnr, result)
  if type(result) ~= "string" or not IMAGE_EXT[(result:match("%.([^./]+)$") or ""):lower()] then
    return false
  end
  local images = require("org.ui.images")
  if not images.backend() then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local needle = "[[file:" .. result .. "]"
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      images.show_links(bufnr, i, i, nil, nil, true)
      return true
    end
  end
  return false
end

local function on_executed(ev)
  local d = ev.data or {}
  if not opts().auto_preview or not langs()[d.lang] or d.inline then
    return
  end
  local bufnr = d.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(M.preview, bufnr, d.result)
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function M.setup(o)
  local ob = require("org.babel.ob")
  local render = require("org.extensions.diagrams.render")
  local bl = require("org.config").opts.babel.languages
  saved = { handlers = {}, languages = {} }
  for _, lang in ipairs(o.languages or {}) do
    if render[lang] then
      saved.handlers[lang] = { value = ob.HANDLERS[lang] }
      ob.HANDLERS[lang] = render[lang]
      if bl[lang] == nil then
        saved.languages[lang] = true
        bl[lang] = { default_header_args = vim.deepcopy(DEFAULT_HEADER_ARGS) }
      end
    end
  end
  group = vim.api.nvim_create_augroup("org_extensions_diagrams", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OrgBabelAfterExecute",
    callback = on_executed,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.org", "*.org_archive" },
    callback = function(ev)
      if opts().render_on_save and not saving[ev.buf] then
        local ok, err = pcall(M.render_after_save, ev.buf)
        if not ok then
          require("org.utils").error("diagrams: " .. tostring(err))
        end
      end
    end,
  })
  if o.cache and (o.cache_max_age or o.cache_max_size) then
    vim.defer_fn(function()
      pcall(M.prune_cache)
    end, 2000)
  end
end

function M.teardown()
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    group = nil
  end
  if not saved then
    return
  end
  local ob = require("org.babel.ob")
  local bl = require("org.config").opts.babel.languages
  for lang, s in pairs(saved.handlers) do
    ob.HANDLERS[lang] = s.value
  end
  for lang in pairs(saved.languages) do
    bl[lang] = nil
  end
  saved = nil
end

function M.health(h, o)
  local render = require("org.extensions.diagrams.render")
  local set = {}
  for _, l in ipairs(o.languages or {}) do
    set[l] = true
  end
  local function tool(lang, cmd, hint)
    if not set[lang] then
      return
    end
    if render.available(cmd) then
      h.ok(string.format("diagrams: %s renders with %s", lang, vim.fs.normalize(vim.fn.exepath(render.program(cmd)))))
    else
      h.warn(string.format("diagrams: %s needs %s (not found)", lang, render.program(cmd)), { hint })
    end
  end
  tool("mermaid", (o.mermaid or {}).command, "npm install -g @mermaid-js/mermaid-cli")
  tool("dot", (o.dot or {}).command, "install Graphviz")
  if set.plantuml then
    local po = require("org.config").opts.babel.languages.plantuml
    if type(po) ~= "table" then
      h.warn("diagrams: plantuml is off in babel.languages")
    elseif (po.jar_path or "") ~= "" and vim.fn.filereadable(vim.fn.expand(po.jar_path)) == 1 then
      if vim.fn.executable("java") == 1 then
        h.ok("diagrams: plantuml renders with " .. po.jar_path)
      else
        h.warn("diagrams: plantuml.jar is set but java is not installed")
      end
    elseif vim.fn.executable(po.executable_path or "plantuml") == 1 then
      h.ok("diagrams: plantuml renders with " .. vim.fs.normalize(vim.fn.exepath(po.executable_path or "plantuml")))
    else
      h.warn("diagrams: plantuml needs the plantuml command or babel.languages.plantuml.jar_path")
    end
  end
  if o.auto_preview then
    local b, why = require("org.ui.images").backend()
    if b then
      h.ok("diagrams: results are previewed inline")
    else
      h.info("diagrams: no inline preview: " .. tostring(why))
    end
  end
  h.info("diagrams: cache in " .. require("org.utils").expand(o.cache_dir))
end

return M
