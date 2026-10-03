---@mod org.export.csl.formatters Output formatters (port of citeproc-formatters.el)

local U = require("org.export.csl.util")
local rt = require("org.export.csl.rt")

local M = {}

local ZWS = U.char(0x200B)
local BOM = U.char(0xFEFF)

local KEY_OF = {
  ["font-style\0italic"] = "font-style-italic",
  ["font-weight\0bold"] = "font-weight-bold",
  ["display\0indent"] = "display-indent",
  ["display\0left-margin"] = "display-left-margin",
  ["display\0right-inline"] = "display-right-inline",
  ["display\0block"] = "display-block",
  ["vertical-align\0sup"] = "vertical-align-sup",
  ["vertical-align\0baseline"] = "vertical-align-baseline",
  ["font-variant\0small-caps"] = "font-variant-small-caps",
  ["text-decoration\0underline"] = "text-decoration-underline",
  ["font-style\0oblique"] = "font-style-oblique",
  ["font-style\0normal"] = "font-style-normal",
  ["font-variant\0normal"] = "font-variant-normal",
  ["font-weight\0light"] = "font-weight-light",
  ["font-weight\0normal"] = "font-weight-normal",
  ["text-decoration\0normal"] = "text-decoration-normal",
  ["vertical-align\0sub"] = "vertical-align-sub",
}

--- citeproc-formatter-fun-create
local function fun_create(fmt)
  local function fmt_rt(r)
    if r == false then
      return nil
    end
    if type(r) == "string" then
      return fmt.unformatted(r)
    elseif type(r) == "table" then
      local parts = {}
      for i = 2, #r do
        local v = fmt_rt(r[i])
        parts[#parts + 1] = v == nil and "" or tostring(v)
      end
      local result = table.concat(parts)
      for _, attr in ipairs(r[1]) do
        if type(attr) == "table" then
          local key = attr[1]
          if key == "href" or key == "cited-item-no" or key == "bib-item-no" then
            local f = fmt[key]
            if f then
              local v = attr[2]
              result = f(result, v == nil and "" or tostring(v))
            end
          else
            local k = type(attr[2]) == "string" and KEY_OF[key .. "\0" .. attr[2]]
            local f = k and fmt[k]
            if f then
              result = f(result)
            end
          end
        end
      end
      return result
    end
    return r
  end
  return fmt_rt
end
M.fun_create = fun_create

local function identity(x)
  return x
end

-- Org

local function org_link(anchor, target)
  if anchor == target then
    return anchor
  end
  return "[[" .. target .. "][" .. anchor .. "]]"
end

local ORG = {
  unformatted = identity,
  href = org_link,
  ["cited-item-no"] = function(x, y)
    return "[[citeproc_bib_item_" .. y .. "][" .. x .. "]]"
  end,
  ["bib-item-no"] = function(x, y)
    return "<<citeproc_bib_item_" .. y .. ">>" .. x
  end,
  ["font-style-italic"] = function(x)
    return ZWS .. "/" .. x .. "/" .. ZWS
  end,
  ["font-style-oblique"] = function(x)
    return ZWS .. "/" .. x .. "/" .. ZWS
  end,
  ["font-weight-bold"] = function(x)
    return ZWS .. "*" .. x .. "*" .. ZWS
  end,
  ["text-decoration-underline"] = function(x)
    return ZWS .. "_" .. x .. "_" .. ZWS
  end,
  ["font-variant-small-caps"] = function(x)
    return U.upcase(x)
  end,
  ["vertical-align-sub"] = function(x)
    return "_{" .. x .. "}"
  end,
  ["vertical-align-sup"] = function(x)
    return "^{" .. x .. "}"
  end,
  ["display-left-margin"] = function(x)
    return x .. " "
  end,
}

local org_rt_1 = fun_create(ORG)

local function org_format_rt(r)
  local result = org_rt_1(r)
  if type(result) == "string" and U.len(result) > 2 then
    result = U.replace_all_seq(result, {
      { " " .. ZWS, " " },
      { ZWS .. " ", " " },
      { ZWS .. ",", "," },
      { ZWS .. ";", ";" },
      { ZWS .. ":", ":" },
      { ZWS .. ".", "." },
    })
    local cps = U.codepoints(result)
    if cps[1] == 0x200B and cps[2] ~= 42 then
      table.remove(cps, 1)
    end
    if cps[#cps] == 0x200B then
      table.remove(cps)
    end
    if cps[1] == 94 then
      table.insert(cps, 1, 0xFEFF)
    end
    result = U.from_codepoints(cps)
  end
  return result
end

-- HTML

local function xml_escape(s)
  return U.replace_all_seq(s, { { "&", "&#38;" }, { "<", "&#60;" }, { ">", "&#62;" } })
end
M.xml_escape = xml_escape

local HTML = {
  unformatted = xml_escape,
  href = function(x, y)
    return '<a href="' .. y .. '">' .. x .. "</a>"
  end,
  ["cited-item-no"] = function(x, y)
    return '<a href="#citeproc_bib_item_' .. y .. '">' .. x .. "</a>"
  end,
  ["bib-item-no"] = function(x, y)
    return '<a id="citeproc_bib_item_' .. y .. '"></a>' .. x
  end,
  ["font-style-italic"] = function(x)
    return "<i>" .. x .. "</i>"
  end,
  ["font-style-oblique"] = function(x)
    return '<span style="font-style:oblique;"' .. x .. "</span>"
  end,
  ["font-variant-small-caps"] = function(x)
    return '<span style="font-variant:small-caps;">' .. x .. "</span>"
  end,
  ["font-weight-bold"] = function(x)
    return "<b>" .. x .. "</b>"
  end,
  ["text-decoration-underline"] = function(x)
    return '<span style="text-decoration:underline;">' .. x .. "</span>"
  end,
  ["vertical-align-sub"] = function(x)
    return "<sub>" .. x .. "</sub>"
  end,
  ["vertical-align-sup"] = function(x)
    return "<sup>" .. x .. "</sup>"
  end,
  ["vertical-align-baseline"] = function(x)
    return '<span style="baseline">' .. x .. "</span>"
  end,
  ["display-left-margin"] = function(x)
    return '\n    <div class="csl-left-margin">' .. x .. "</div>"
  end,
  ["display-right-inline"] = function(x)
    return '<div class="csl-right-inline">' .. x .. "</div>\n  "
  end,
  ["display-block"] = function(x)
    return '\n\n    <div class="csl-block">' .. x .. "</div>\n"
  end,
  ["display-indent"] = function(x)
    return '<div class="csl-indent">' .. x .. "</div>\n  "
  end,
}

local function html_bib(items)
  local out = { '<div class="csl-bib-body">\n' }
  for _, i in ipairs(items) do
    out[#out + 1] = '  <div class="csl-entry">' .. i .. "</div>\n"
  end
  out[#out + 1] = "</div>"
  return table.concat(out)
end

-- LaTeX

local function latex_escape(s)
  return (s:gsub("[_&#%%%${}]", "\\%0"))
end

local function latex_href(text, uri)
  local escaped = uri:gsub("[#%%]", "\\%0")
  if U.starts_with(text, "http") then
    return "\\url{" .. escaped .. "}"
  end
  return "\\href{" .. escaped .. "}{" .. text .. "}"
end

local ORG_LATEX = {
  unformatted = latex_escape,
  href = latex_href,
  ["font-style-italic"] = function(x)
    return "\\textit{" .. x .. "}"
  end,
  ["font-weight-bold"] = function(x)
    return "\\textbf{" .. x .. "}"
  end,
  ["cited-item-no"] = function(x, y)
    return "\\cslcitation{" .. y .. "}{" .. x .. "}"
  end,
  ["bib-item-no"] = function(x, y)
    return "\\cslbibitem{" .. y .. "}{" .. x .. "}"
  end,
  ["font-variant-small-caps"] = function(x)
    return "\\textsc{" .. x .. "}"
  end,
  ["text-decoration-underline"] = function(x)
    return "\\underline{" .. x .. "}"
  end,
  ["vertical-align-sup"] = function(x)
    return "\\textsuperscript{" .. x .. "}"
  end,
  ["display-left-margin"] = function(x)
    return "\\cslleftmargin{" .. x .. "}"
  end,
  ["display-right-inline"] = function(x)
    return "\\cslrightinline{" .. x .. "}"
  end,
  ["display-block"] = function(x)
    return "\\cslblock{" .. x .. "}"
  end,
  ["display-indent"] = function(x)
    return "\\cslindent{" .. x .. "}"
  end,
  ["vertical-align-sub"] = function(x)
    return "\\textsubscript{" .. x .. "}"
  end,
  ["font-style-oblique"] = function(x)
    return "\\textsl{" .. x .. "}"
  end,
}

local function org_latex_bib(items, params)
  local hanging = params and U.aget(params, "hanging-indent") and "1" or "0"
  local es = params and U.aget(params, "entry-spacing")
  local spacing = (es and type(es) == "number" and es >= 1) and U.num_str(es - 1) or "0"
  return "\\begin{cslbibliography}{"
    .. hanging
    .. "}{"
    .. spacing
    .. "}\n"
    .. table.concat(items, "\n\n")
    .. "\n\n\\end{cslbibliography}\n"
end

local LATEX = vim.tbl_extend("force", {}, ORG_LATEX, {
  ["cited-item-no"] = function(x, y)
    return "\\citeprocitem{" .. y .. "}{" .. x .. "}"
  end,
  ["bib-item-no"] = function(x, y)
    return "\\hypertarget{citeproc_bib_item_" .. y .. "}{" .. x .. "}"
  end,
  ["display-left-margin"] = function(x)
    return x .. " "
  end,
})
LATEX["display-right-inline"] = nil
LATEX["display-block"] = nil
LATEX["display-indent"] = nil

local function default_bib(items)
  return table.concat(items, "\n\n")
end

local CSL_TEST = vim.tbl_extend("force", {}, HTML, {
  ["vertical-align-baseline"] = function(x)
    return '<span class="baseline">' .. x .. "</span>"
  end,
})
CSL_TEST.href = nil

--- Formatter structs: { rt, cite, bib_item, bib, no_external_links }.
M.formatters = {
  html = { rt = fun_create(HTML), bib = html_bib },
  ["csl-test"] = { rt = fun_create(CSL_TEST), bib = html_bib, no_external_links = true },
  org = { rt = org_format_rt },
  ["org-latex"] = { rt = fun_create(ORG_LATEX), bib = org_latex_bib },
  latex = {
    rt = fun_create(LATEX),
    bib = function(items)
      return table.concat(items, "\n\n") .. "\\bigskip"
    end,
  },
  plain = { rt = rt.to_plain, no_external_links = true },
  raw = {
    rt = identity,
    bib = function(x)
      return x
    end,
  },
}

--- citeproc-formatter-for-format
function M.for_format(format)
  local f = M.formatters[format]
  if not f then
    error(string.format("No formatter for citeproc format `%s'", tostring(format)), 0)
  end
  return {
    rt = f.rt,
    cite = f.cite or identity,
    bib_item = f.bib_item or function(x, _params)
      return x
    end,
    bib = f.bib or default_bib,
    no_external_links = f.no_external_links,
  }
end

return M
