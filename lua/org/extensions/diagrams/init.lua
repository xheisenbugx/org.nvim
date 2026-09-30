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
  --- Render every diagram block of an org buffer when it is written.
  render_on_save = false,
}

M.actions = {
  diagrams_render = { MOD, "render", desc = "Render the diagram block at point" },
  diagrams_rerender = { MOD, "rerender", desc = "Render the diagram block at point, ignoring the cache" },
  diagrams_render_buffer = { MOD, "render_buffer", desc = "Render every diagram block of the buffer" },
  diagrams_clear_cache = { MOD, "clear_cache", desc = "Delete the rendered-diagram cache" },
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

--- Delete the cached diagrams.
function M.clear_cache()
  local dir = require("org.utils").expand(opts().cache_dir)
  local n = 0
  for _, f in ipairs(vim.fn.glob(dir .. "/*", true, true)) do
    if vim.fn.delete(f) == 0 then
      n = n + 1
    end
  end
  require("org.utils").notify(string.format("diagrams: removed %d cached file(s)", n))
  return n
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
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    pattern = { "*.org", "*.org_archive" },
    callback = function(ev)
      if opts().render_on_save then
        local ok, err = pcall(M.render_buffer, ev.buf)
        if not ok then
          require("org.utils").error("diagrams: " .. tostring(err))
        end
      end
    end,
  })
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
      h.ok(string.format("diagrams: %s renders with %s", lang, vim.fn.exepath(render.program(cmd))))
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
      h.ok("diagrams: plantuml renders with " .. vim.fn.exepath(po.executable_path or "plantuml"))
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
