---@mod org.export.odt.backend ODT filters and back-end
---
--- The export filters of ox-odt.el, the option defaults and the back-end
--- definition.
---
--- Part of org.export.odt, which loads it.

local ox = require("org.export.ox")
local element = require("org.export.element")
local shared = require("org.export.odt.shared")

local M = require("org.export.odt")

local fmt = string.format

local ocfg = shared.ocfg
local new_state = shared.new_state
local latex_processes = shared.latex_processes
local latex_process_available = shared.latex_process_available
local T = shared.T

---------------------------------------------------------------------------
-- Filters
---------------------------------------------------------------------------

--- org-odt--strip-trailing-newlines
local function strip_trailing_newlines(tree, _, info)
  element.map(tree, "*", function(el)
    if element.ELEMENTS[el.type] then
      local c = el.contents
      local last = c and c[#c]
      if last and last.type == "plain-text" and last.value:sub(-1) == "\n" then
        if #last.value > 1 then
          last.value = last.value:sub(1, -2)
        else
          table.remove(c)
        end
      end
    end
  end, { ignore = info.ignore, with_affiliated = true })
  return tree
end

--- org-odt--translate-latex-fragments: normalize `tex:` and convert the
--- fragments to MathML or pictures.
local function translate_latex_fragments(tree, _, info)
  local mode = info.with_latex
  if not mode then
    return tree
  end
  local warning
  local processes = latex_processes()
  if mode == true or mode == "t" or mode == "mathml" then
    if M.mathml_available() then
      mode = "mathml"
    else
      warning = "`org-odt-with-latex': LaTeX to MathML converter not available.  Falling back to verbatim."
      mode = "verbatim"
    end
  elseif type(mode) == "string" and processes[mode] then
    if not latex_process_available(mode) then
      warning = "`org-odt-with-latex': LaTeX to image converter not available.  Falling back to verbatim."
      mode = "verbatim"
    end
  elseif mode ~= "verbatim" then
    warning = "`org-odt-with-latex': Unknown LaTeX option.  Forcing verbatim."
    mode = "verbatim"
  end
  local frags = element.map(tree, { ["latex-fragment"] = true, ["latex-environment"] = true }, function(x)
    return x
  end, { ignore = info.ignore, with_affiliated = true })
  if warning and #frags > 0 then
    require("org.utils").warn(warning)
  end
  info.with_latex = mode
  if mode == "verbatim" then
    return tree
  end
  for _, x in ipairs(frags) do
    local value = x.value or ""
    if mode == "mathml" then
      local mathml = M.latex_to_mathml_cached(value, info)
      if mathml then
        x.odt_converted = { kind = "mathml", data = mathml }
      end
    else
      local path = M.latex_to_image(value, mode, info)
      if path then
        x.odt_converted = { kind = "image", data = path }
      else
        require("org.utils").warn("LaTeX Conversion failed.")
      end
    end
  end
  return tree
end

--- org-odt--translate-description-lists: description lists become a list
--- of terms (bold paragraphs) each followed by a list with its definition.
local function translate_description_lists(tree, _, info)
  element.map(tree, "plain-list", function(el)
    if el.list_type == "descriptive" then
      local items = {}
      for _, item in ipairs(el.contents) do
        local term = item.tag and #item.tag > 0 and item.tag or { element.text("(no term)") }
        local para = element.node("paragraph", { odt_style = "Text_20_body_20_bold" }, term)
        local inner = element.node("item", {}, item.contents)
        local list = element.node("plain-list", { list_type = "descriptive-2" }, { inner })
        items[#items + 1] = element.node("item", { checkbox = item.checkbox }, { para, list })
      end
      -- a new list in Emacs (org-element-set): no blank lines after it
      el.list_type = "descriptive-1"
      el.post_blank = 0
      el.contents = items
      for _, it in ipairs(items) do
        it.parent = el
      end
    end
  end, { ignore = info.ignore })
  return tree
end

--- org-odt--translate-list-tables: lists with `#+ATTR_ODT: :list-table t`
--- become tables (level-1 items are rows, level-2 items the cells).
local function translate_list_tables(tree, _, info)
  local lists = element.map(tree, "plain-list", function(el)
    if ox.read_attribute("attr_odt", el, "list-table") then
      return el
    end
  end, { ignore = info.ignore })
  for _, l1 in ipairs(lists) do
    local rows = {}
    for _, item in ipairs(l1.contents) do
      if item.type == "item" then
        local leading, l2 = {}, nil
        local found = false
        for i, x in ipairs(item.contents) do
          if x.type == "plain-list" and i > 1 then
            l2 = x
            found = true
            break
          end
          leading[#leading + 1] = x
        end
        if not found then
          leading = item.contents
        end
        local cells = { element.node("table-cell", {}, leading) }
        for _, it in ipairs(l2 and l2.contents or {}) do
          if it.type == "item" then
            cells[#cells + 1] = element.node("table-cell", {}, it.contents)
          end
        end
        rows[#rows + 1] = element.node("table-row", { row_type = "standard" }, cells)
      end
    end
    local tbl = element.node("table", { table_type = "org", attr_odt = { ':style "GriddedTable"' } }, rows)
    local siblings = element.siblings(l1)
    if siblings then
      for i, x in ipairs(siblings) do
        if x == l1 then
          siblings[i] = tbl
          tbl.parent = l1.parent
          break
        end
      end
    end
  end
  return tree
end

local function translate_image_links(tree, _, info)
  return ox.insert_image_links(tree, info, info.odt_inline_image_rules)
end

--- org-odt--remove-forbidden: characters not allowed in XML 1.0.
local function remove_forbidden(text, _, info)
  local rep = info.odt_with_forbidden_chars
  if rep == true then
    return text
  end
  local pat = "[%z\1-\8\11\12\14-\31]"
  local pat2 = "\239\191[\190\191]"
  if rep == false or rep == nil then
    local m = text:match(pat) or text:match(pat2)
    if m then
      error(fmt("Forbidden character '%s' found.  See `export.odt.with_forbidden_chars'", m), 0)
    end
    return text
  end
  local counts = {}
  local function sub(c)
    counts[c] = (counts[c] or 0) + 1
    return rep
  end
  text = text:gsub(pat, sub):gsub(pat2, sub)
  for c, n in pairs(counts) do
    require("org.utils").warn(fmt("Replaced forbidden character %q with '%s' %d times", c, rep, n))
  end
  return text
end

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

local function defaults()
  local c = ocfg()
  local function v(name, default)
    if c[name] == nil then
      return default
    end
    return c[name]
  end
  local global_latex = (require("org.config").opts.export or {}).with_latex
  if global_latex == nil then
    global_latex = true
  end
  return {
    { "odt_styles_file", "ODT_STYLES_FILE", nil, v("styles_file", nil), "t" },
    { "odt_extra_styles", "ODT_EXTRA_STYLES", nil, v("extra_styles", nil), "newline" },
    { "description", "DESCRIPTION", nil, nil, "newline" },
    { "keywords_meta", "KEYWORDS", nil, nil, "space" },
    { "subtitle", "SUBTITLE", nil, nil, "parse" },
    { "odt_with_forbidden_chars", nil, nil, v("with_forbidden_chars", "") },
    { "odt_content_template_file", nil, nil, v("content_template_file", nil) },
    { "odt_display_outline_level", nil, nil, v("display_outline_level", 2) },
    { "odt_fontify_srcblocks", nil, nil, v("fontify_srcblocks", true) },
    { "odt_create_custom_styles_for_srcblocks", nil, nil, v("create_custom_styles_for_srcblocks", true) },
    { "odt_format_drawer_function", nil, nil, v("format_drawer_function", nil) },
    { "odt_format_headline_function", nil, nil, v("format_headline_function", nil) },
    { "odt_format_inlinetask_function", nil, nil, v("format_inlinetask_function", nil) },
    { "odt_inline_formula_rules", nil, nil, v("inline_formula_rules", { file = { "mathml", "mml", "odf" } }) },
    { "odt_inline_image_rules", nil, nil, v("inline_image_rules", { file = { "jpeg", "jpg", "png", "gif", "svg" } }) },
    { "odt_pixels_per_inch", nil, nil, v("pixels_per_inch", 96) },
    { "odt_table_styles", nil, nil, v("table_styles", M.TABLE_STYLES) },
    { "odt_use_date_fields", nil, nil, v("use_date_fields", false) },
    { "odt_category_map_alist", nil, nil, v("category_map_alist", nil) },
    { "with_latex", nil, "tex", v("with_latex", global_latex) },
    { "latex_header", "LATEX_HEADER", nil, nil, "newline" },
  }
end

M.transcoders = T

M.backend = ox.define_backend("odt", {
  transcoders = T,
  options = defaults,
  filters = {
    options = {
      function(info)
        info.odt_state = new_state()
        return info
      end,
    },
    ["parse-tree"] = {
      strip_trailing_newlines,
      translate_latex_fragments,
      translate_description_lists,
      translate_list_tables,
      translate_image_links,
    },
    ["final-output"] = { remove_forbidden },
  },
})
