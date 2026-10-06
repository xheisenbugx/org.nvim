---@mod org.extensions.hugo Hugo export (port of ox-hugo)
---
--- Enable with `extensions = { hugo = { base_dir = "~/site" } }` (see
--- `:h org-extensions-hugo`). It adds the `hugo` export back-end
--- (`org.extensions.hugo.backend`), the `H` entry of the export dispatcher
--- and the `hugo_*` actions; the commands are in
--- `org.extensions.hugo.export`.

local MOD = "org.extensions.hugo"

local M = {}

M.defaults = {
  --- The Hugo site (org-hugo-base-dir); `#+hugo_base_dir` or the
  --- EXPORT_HUGO_BASE_DIR property set it per file or subtree.
  base_dir = nil,
  --- The content directory under the base dir (org-hugo-content-folder).
  content_folder = "content",
  --- The section of posts (org-hugo-section).
  section = "posts",
  --- "toml" or "yaml" (org-hugo-front-matter-format).
  front_matter_format = "toml",
  --- Text put at the end of every post (org-hugo-footer).
  footer = "",
  --- Keep the line breaks of filled paragraphs (org-hugo-preserve-filling).
  preserve_filling = true,
  --- Delete trailing whitespace and blank lines (org-hugo-delete-trailing-ws).
  delete_trailing_ws = true,
  --- `~code~` as <kbd> (org-hugo-use-code-for-kbd).
  use_code_for_kbd = false,
  --- `a__b` tags as "a b" (org-hugo-allow-spaces-in-tags).
  allow_spaces_in_tags = true,
  --- `a_b` tags as "a-b", `a___b` as "a_b" (org-hugo-prefer-hyphen-in-tags).
  prefer_hyphen_in_tags = true,
  --- Set lastmod to the time of the export (org-hugo-auto-set-lastmod).
  auto_set_lastmod = false,
  --- Seconds after the post's date during which the automatic lastmod is
  --- left out (org-hugo-suppress-lastmod-period).
  suppress_lastmod_period = 0,
  --- Table of contents: false, true or a depth (org-hugo-export-with-toc).
  with_toc = false,
  --- Section numbers: false, true, a level or "onlytoc"
  --- (org-hugo-export-with-section-numbers).
  with_section_numbers = false,
  --- Subdirectory of static/ for linked files outside it
  --- (org-hugo-default-static-subdirectory-for-externals).
  static_subdir = "ox-hugo",
  --- Extensions of linked files copied to the site
  --- (org-hugo-external-file-extensions-allowed-for-copying).
  copy_extensions = {
    "jpg",
    "jpeg",
    "tiff",
    "png",
    "svg",
    "gif",
    "bmp",
    "mp4",
    "pdf",
    "odt",
    "doc",
    "ppt",
    "xls",
    "docx",
    "pptx",
    "xlsx",
  },
  --- format-time-string format of front matter dates (org-hugo-date-format).
  date_format = "%Y-%m-%dT%T%z",
  --- Space-separated paired shortcodes; "%name" for Markdown contents
  --- (org-hugo-paired-shortcodes).
  paired_shortcodes = "",
  --- "Figure 1" instead of "1" for links to numbered elements
  --- (org-hugo-link-desc-insert-type).
  link_desc_insert_type = false,
  --- HTML element wrapping top-level sections (org-hugo-container-element).
  container_element = "",
  --- Per special block type: `raw` (contents as typed), `trim-pre`,
  --- `trim-post` (org-hugo-special-block-type-properties).
  special_block_type_properties = {
    audio = { raw = true },
    katex = { raw = true },
    mark = { ["trim-pre"] = true, ["trim-post"] = true },
    tikzjax = { raw = true },
    video = { raw = true },
  },
  --- `{#anchor}` after headings (org-hugo-headline-anchor).
  headline_anchor = true,
  --- Export the post at the cursor (or the file) when a buffer with a
  --- Hugo base dir is written (org-hugo-auto-export-mode).
  auto_export = false,
}

M.actions = {
  hugo_export_wim = {
    MOD,
    "export_wim",
    desc = "Hugo: export the post subtree at the cursor (or the file) to Markdown",
  },
  hugo_export_all = { MOD, "export_all", desc = "Hugo: export all post subtrees (or the file) to Markdown" },
  hugo_export_file = { MOD, "export_file", desc = "Hugo: export the whole file as one post" },
  hugo_export_buffer = { MOD, "export_buffer", desc = "Hugo: export the file to a temporary Markdown buffer" },
}

M.commands = {
  hugo = {
    MOD,
    "command",
    desc = "Hugo export: :Org hugo [wim|all|file|buffer] [open] [visible]",
    complete = function()
      return { "wim", "all", "file", "buffer", "open", "visible" }
    end,
  },
}

local function export()
  return require("org.extensions.hugo.export")
end

function M.export_wim()
  return export().export_wim()
end

function M.export_all()
  return export().export_wim({ all = true })
end

function M.export_file()
  return export().export_file()
end

function M.export_buffer()
  return export().export_as_buffer()
end

--- :Org hugo [wim|all|file|buffer] [open] [visible]
---@param args? string
function M.command(args)
  local words = vim.split(vim.trim(args or ""), "%s+", { trimempty = true })
  local what = "wim"
  local o = {}
  for _, w in ipairs(words) do
    if w == "open" then
      o.open = true
    elseif w == "visible" then
      o.visible_only = true
    else
      what = w
    end
  end
  if what == "all" then
    o.all = true
    return export().export_wim(o)
  elseif what == "file" then
    return export().export_file(o)
  elseif what == "buffer" then
    return export().export_as_buffer(o)
  elseif what == "wim" then
    return export().export_wim(o)
  end
  require("org.utils").error("Usage: :Org hugo [wim|all|file|buffer] [open] [visible]")
end

--- The `H` entry of the export dispatcher (ox-hugo's menu entry).
local function menu_entry()
  local function run(fn)
    return function(state, ctx)
      return fn(state, ctx)
    end
  end
  return {
    key = "H",
    label = "Export to Hugo-compatible Markdown",
    items = {
      {
        key = "H",
        label = "Subtree or file to Md file",
        value = {
          fn = run(function(state)
            return export().export_wim({ visible_only = state.visible_only })
          end),
        },
      },
      {
        key = "h",
        label = "File to Md file",
        value = {
          fn = run(function(state)
            return export().export_to_md({ subtree = state.subtree, visible_only = state.visible_only })
          end),
        },
      },
      {
        key = "O",
        label = "Subtree or file to Md file and open",
        value = {
          fn = run(function(state)
            return export().export_wim({ visible_only = state.visible_only, open = true })
          end),
        },
      },
      {
        key = "o",
        label = "File to Md file and open",
        value = {
          fn = run(function(state)
            return export().export_to_md({ subtree = state.subtree, visible_only = state.visible_only, open = true })
          end),
        },
      },
      {
        key = "A",
        label = "All subtrees (or file) to Md file(s)",
        value = {
          fn = run(function(state)
            return export().export_wim({ all = true, visible_only = state.visible_only })
          end),
        },
      },
      {
        key = "t",
        label = "File to a temporary Md buffer",
        value = {
          fn = run(function(state, ctx)
            return export().export_as_buffer({
              subtree = state.subtree,
              line = ctx and ctx.subtree_line,
              visible_only = state.visible_only,
            })
          end),
        },
      },
    },
  }
end

local HOOK = "hugo-auto-export"

function M.setup(opts)
  require("org.extensions.hugo.backend")
  require("org.export").register_menu_entry(menu_entry())
  if opts.auto_export then
    require("org.write_hooks").register(HOOK, {
      order = 90,
      filetype = "org",
      post = function(bufnr, ctx)
        if not ctx.ok or not export().has_base_dir(bufnr) then
          return
        end
        local line
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(w) == bufnr then
            line = vim.api.nvim_win_get_cursor(w)[1]
            break
          end
        end
        export().export_wim({ bufnr = bufnr, line = line or 1, noerror = true })
      end,
    })
  end
end

function M.teardown()
  require("org.export").unregister_menu_entry("H")
  require("org.write_hooks").unregister(HOOK)
end

function M.health(h, opts)
  if opts.base_dir then
    local dir = require("org.utils").expand(opts.base_dir, vim.fn.getcwd())
    if vim.fn.isdirectory(dir) == 1 then
      h.ok("hugo: base_dir " .. dir)
    else
      h.warn("hugo: base_dir " .. dir .. " does not exist")
    end
  else
    h.info("hugo: no base_dir; set #+hugo_base_dir in each file")
  end
  if vim.fn.executable("hugo") == 1 then
    h.ok("hugo: the hugo command is installed")
  else
    h.info("hugo: the hugo command is not installed (only needed to build the site)")
  end
end

return M
