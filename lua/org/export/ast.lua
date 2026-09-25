---@mod org.export.ast Org document -> export AST
---
--- Element nodes:
---   headline  { level, title (inline), todo, todo_type, priority, tags, children, id, number, planning, properties, deep }
---   paragraph { inline }                  hr {}
---   list      { kind = "unordered"|"ordered"|"description", items = { {bullet, checkbox, term (inline), children} } }
---   table     { rows = { {cells (inline[])} | "hline" }, header = n, affiliated }
---   src       { lang, lines, params, affiliated }   example { lines }   fixed { lines }
---   quote     { children }  center { children }  verse { lines (inline[]) }
---   special   { name, children }   export { backend, lines }   latex_env { lines }
---   keyword_toc { depth }
--- Inline nodes:
---   text{value} bold/italic/underline/strike{children} verbatim/code{value}
---   link{path, kind, desc (inline|nil), raw} footnote_ref{label, def (inline|nil)}
---   linebreak{} timestamp{value} latex{value} entity{name} target{value}
---   sub/sup{children} snippet{backend, value}

local parser = require("org.parser")
local blocks = require("org.babel.blocks")

local M = {}

---------------------------------------------------------------------------
-- Entities
---------------------------------------------------------------------------

-- name = { html, utf8, latex }
M.ENTITIES = {
  alpha = { "&alpha;", "α", "$\\alpha$" },
  beta = { "&beta;", "β", "$\\beta$" },
  gamma = { "&gamma;", "γ", "$\\gamma$" },
  delta = { "&delta;", "δ", "$\\delta$" },
  epsilon = { "&epsilon;", "ε", "$\\epsilon$" },
  zeta = { "&zeta;", "ζ", "$\\zeta$" },
  eta = { "&eta;", "η", "$\\eta$" },
  theta = { "&theta;", "θ", "$\\theta$" },
  iota = { "&iota;", "ι", "$\\iota$" },
  kappa = { "&kappa;", "κ", "$\\kappa$" },
  lambda = { "&lambda;", "λ", "$\\lambda$" },
  mu = { "&mu;", "μ", "$\\mu$" },
  nu = { "&nu;", "ν", "$\\nu$" },
  xi = { "&xi;", "ξ", "$\\xi$" },
  pi = { "&pi;", "π", "$\\pi$" },
  rho = { "&rho;", "ρ", "$\\rho$" },
  sigma = { "&sigma;", "σ", "$\\sigma$" },
  tau = { "&tau;", "τ", "$\\tau$" },
  upsilon = { "&upsilon;", "υ", "$\\upsilon$" },
  phi = { "&phi;", "φ", "$\\phi$" },
  chi = { "&chi;", "χ", "$\\chi$" },
  psi = { "&psi;", "ψ", "$\\psi$" },
  omega = { "&omega;", "ω", "$\\omega$" },
  Gamma = { "&Gamma;", "Γ", "$\\Gamma$" },
  Delta = { "&Delta;", "Δ", "$\\Delta$" },
  Theta = { "&Theta;", "Θ", "$\\Theta$" },
  Lambda = { "&Lambda;", "Λ", "$\\Lambda$" },
  Xi = { "&Xi;", "Ξ", "$\\Xi$" },
  Pi = { "&Pi;", "Π", "$\\Pi$" },
  Sigma = { "&Sigma;", "Σ", "$\\Sigma$" },
  Phi = { "&Phi;", "Φ", "$\\Phi$" },
  Psi = { "&Psi;", "Ψ", "$\\Psi$" },
  Omega = { "&Omega;", "Ω", "$\\Omega$" },
  to = { "&rarr;", "→", "$\\to$" },
  rarr = { "&rarr;", "→", "$\\rightarrow$" },
  rightarrow = { "&rarr;", "→", "$\\rightarrow$" },
  larr = { "&larr;", "←", "$\\leftarrow$" },
  leftarrow = { "&larr;", "←", "$\\leftarrow$" },
  uarr = { "&uarr;", "↑", "$\\uparrow$" },
  darr = { "&darr;", "↓", "$\\downarrow$" },
  harr = { "&harr;", "↔", "$\\leftrightarrow$" },
  Rightarrow = { "&rArr;", "⇒", "$\\Rightarrow$" },
  Leftarrow = { "&lArr;", "⇐", "$\\Leftarrow$" },
  deg = { "&deg;", "°", "$^{\\circ}$" },
  pm = { "&plusmn;", "±", "$\\pm$" },
  times = { "&times;", "×", "$\\times$" },
  div = { "&divide;", "÷", "$\\div$" },
  le = { "&le;", "≤", "$\\le$" },
  leq = { "&le;", "≤", "$\\le$" },
  ge = { "&ge;", "≥", "$\\ge$" },
  geq = { "&ge;", "≥", "$\\ge$" },
  ne = { "&ne;", "≠", "$\\ne$" },
  neq = { "&ne;", "≠", "$\\neq$" },
  approx = { "&asymp;", "≈", "$\\approx$" },
  infin = { "&infin;", "∞", "$\\infty$" },
  infty = { "&infin;", "∞", "$\\infty$" },
  sum = { "&sum;", "∑", "$\\sum$" },
  prod = { "&prod;", "∏", "$\\prod$" },
  cdot = { "&sdot;", "⋅", "$\\cdot$" },
  hellip = { "&hellip;", "…", "\\dots{}" },
  dots = { "&hellip;", "…", "\\dots{}" },
  nbsp = { "&nbsp;", " ", "~" },
  copy = { "&copy;", "©", "\\textcopyright{}" },
  reg = { "&reg;", "®", "\\textregistered{}" },
  trade = { "&trade;", "™", "\\texttrademark{}" },
  mdash = { "&mdash;", "—", "---" },
  ndash = { "&ndash;", "–", "--" },
  laquo = { "&laquo;", "«", "\\guillemotleft{}" },
  raquo = { "&raquo;", "»", "\\guillemotright{}" },
  euro = { "&euro;", "€", "\\texteuro{}" },
  pound = { "&pound;", "£", "\\pounds{}" },
  yen = { "&yen;", "¥", "\\textyen{}" },
  cent = { "&cent;", "¢", "\\textcent{}" },
  para = { "&para;", "¶", "\\P{}" },
  sect = { "&sect;", "§", "\\S{}" },
  vert = { "&vert;", "|", "\\vert{}" },
  ast = { "&lowast;", "∗", "$\\ast$" },
  checkmark = { "&#x2713;", "✓", "\\checkmark{}" },
  star = { "&#x22C6;", "⋆", "$\\star$" },
  partial = { "&part;", "∂", "$\\partial$" },
  nabla = { "&nabla;", "∇", "$\\nabla$" },
  forall = { "&forall;", "∀", "$\\forall$" },
  exists = { "&exist;", "∃", "$\\exists$" },
  isin = { "&isin;", "∈", "$\\in$" },
  ["in"] = { "&isin;", "∈", "$\\in$" },
  empty = { "&empty;", "∅", "$\\emptyset$" },
  sqrt = { "&radic;", "√", "$\\sqrt{\\,}$" },
}

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

local function opt_value(v)
  if v == "t" then
    return true
  elseif v == "nil" then
    return false
  elseif tonumber(v) then
    return tonumber(v)
  end
  return v
end

--- Iterate `key:value` pairs of an #+OPTIONS line. Values may be lists in
--- parentheses (`tasks:("TODO" "NEXT")`) or quoted strings.
function M.option_pairs(line)
  local pairs_list = {}
  local i, n = 1, #line
  while i <= n do
    local ks, ke, key = line:find("([^%s:]+):", i)
    if not ks then
      break
    end
    local rest = line:sub(ke + 1)
    local value = rest:match("^%b()") or rest:match('^"[^"]*"') or rest:match("^%S*")
    pairs_list[#pairs_list + 1] = { key, value }
    i = ke + 1 + #value
  end
  local k = 0
  return function()
    k = k + 1
    local p = pairs_list[k]
    if p then
      return p[1], p[2]
    end
  end
end

--- Export options from config + #+OPTIONS keywords (+ `extra_options`
--- lines such as a subtree's EXPORT_OPTIONS property).
function M.options(settings, overrides, extra_options)
  local cfg = require("org.config").opts.export or {}
  local o = {
    toc = cfg.with_toc ~= false,
    num = cfg.with_section_numbers ~= false,
    H = cfg.headline_levels or 3,
    todo = cfg.with_todo_keywords ~= false,
    tags = cfg.with_tags ~= false,
    pri = cfg.with_priority == true,
    author = cfg.with_author ~= false,
    date = cfg.with_date ~= false,
    email = false,
    title = true,
    drawers = cfg.with_drawers == true,
    planning = cfg.with_planning == true,
    timestamps = cfg.with_timestamps ~= false,
    sub = true,
    linebreaks = false,
    special_strings = true,
    emphasis = true,
    footnotes = true,
    tables = true,
    latex = true,
    tasks = true,
    arch = "headline",
    entities = true,
    stat = true,
    prop = false,
    clocks = false,
    select_tags = cfg.select_tags or { "export" },
    exclude_tags = cfg.exclude_tags or { "noexport" },
  }
  local map = {
    toc = "toc",
    num = "num",
    H = "H",
    todo = "todo",
    tags = "tags",
    pri = "pri",
    author = "author",
    date = "date",
    email = "email",
    title = "title",
    d = "drawers",
    p = "planning",
    ["<"] = "timestamps",
    ["^"] = "sub",
    ["\\n"] = "linebreaks",
    ["-"] = "special_strings",
    ["*"] = "emphasis",
    f = "footnotes",
    ["|"] = "tables",
    tex = "latex",
    tasks = "tasks",
    arch = "arch",
    e = "entities",
    stat = "stat",
    prop = "prop",
    c = "clocks",
  }
  local option_lines = vim.list_extend(vim.deepcopy(settings.keywords.OPTIONS or {}), extra_options or {})
  for _, line in ipairs(option_lines) do
    for key, value in M.option_pairs(line) do
      local name = map[key]
      if name then
        if value == "{}" then
          o[name] = "{}"
        elseif value:match("^%(.*%)$") then
          -- a list of strings: tasks:("TODO" "NEXT"), d:("NOTES"), prop:("A")
          local list = {}
          for s in value:sub(2, -2):gmatch('"(.-)"') do
            list[#list + 1] = s
          end
          if value:match('^%(%s*not%s') then
            list.negate = true
          end
          o[name] = list
        else
          o[name] = opt_value(value)
        end
      end
    end
  end
  for _, v in ipairs(settings.keywords.SELECT_TAGS or {}) do
    o.select_tags = vim.split(v, "%s+", { trimempty = true })
  end
  for _, v in ipairs(settings.keywords.EXCLUDE_TAGS or {}) do
    o.exclude_tags = vim.split(v, "%s+", { trimempty = true })
  end
  for k, v in pairs(overrides or {}) do
    o[k] = v
  end
  return o
end

---------------------------------------------------------------------------
-- Inline parsing
---------------------------------------------------------------------------

local MARKERS = { ["*"] = "bold", ["/"] = "italic", ["_"] = "underline", ["+"] = "strike", ["="] = "verbatim", ["~"] = "code" }
local PRE = "[%s%-%(%{'\"]"
local POST = "[%s%-%.,:!%?;'\"%)%}%[\\]"

local function find_closing(s, i, marker)
  local j = i + 2
  local n = #s
  while j <= n do
    j = s:find(marker, j, true)
    if not j then
      return nil
    end
    local before = s:sub(j - 1, j - 1)
    local after = s:sub(j + 1, j + 1)
    if not before:match("%s") and (after == "" or after:match(POST)) and j > i + 1 then
      return j
    end
    j = j + 1
  end
end

--- Parse inline markup of a string.
---@param s string
---@param o? table export options
---@return table[] nodes
function M.parse_inline(s, o)
  o = o or {}
  local nodes = {}
  local buf = {}
  local function flush()
    if #buf > 0 then
      nodes[#nodes + 1] = { type = "text", value = table.concat(buf) }
      buf = {}
    end
  end
  local function push(node)
    flush()
    nodes[#nodes + 1] = node
  end
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    local rest = s:sub(i)
    local handled = false
    if c == "[" then
      local path, desc = rest:match("^%[%[([^%]]+)%]%[(.-)%]%]")
      local len
      if path then
        len = #path + #desc + 6
        push({ type = "link", path = path, desc = M.parse_inline(desc, o), raw = rest:sub(1, len) })
        handled = true
      else
        path = rest:match("^%[%[([^%]]+)%]%]")
        if path then
          len = #path + 4
          push({ type = "link", path = path, raw = rest:sub(1, len) })
          handled = true
        end
      end
      if not handled then
        local label, def = rest:match("^%[fn:([^%]:]*):(.-)%]")
        if label then
          len = #label + #def + 5
          push({ type = "footnote_ref", label = label ~= "" and label or nil, def = M.parse_inline(def, o) })
          handled = true
        else
          label = rest:match("^%[fn:([^%]:]+)%]")
          if label then
            len = #label + 5
            push({ type = "footnote_ref", label = label })
            handled = true
          end
        end
      end
      if not handled then
        local ts = rest:match("^(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%]%-%-%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])")
          or rest:match("^(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])")
        if ts then
          len = #ts
          push({ type = "timestamp", value = ts })
          handled = true
        end
      end
      if handled then
        i = i + len
      end
    elseif c == "<" then
      local ts = rest:match("^(<%d%d%d%d%-%d%d%-%d%d[^>]*>%-%-<%d%d%d%d%-%d%d%-%d%d[^>]*>)")
        or rest:match("^(<%d%d%d%d%-%d%d%-%d%d[^>]*>)")
      if ts then
        push({ type = "timestamp", value = ts })
        i = i + #ts
        handled = true
      else
        local radio = rest:match("^<<<([^<>]+)>>>")
        local target = rest:match("^<<([^<>]+)>>")
        if radio then
          -- radio target: an anchor that keeps its text
          push({ type = "target", value = radio, radio = true })
          nodes[#nodes + 1] = { type = "text", value = radio }
          i = i + #radio + 6
          handled = true
        elseif target and not rest:match("^<<<") then
          push({ type = "target", value = target })
          i = i + #target + 4
          handled = true
        else
          local url = rest:match("^<(%a[%w+.%-]*:[^>%s]+)>")
          if url then
            push({ type = "link", path = url, raw = "<" .. url .. ">" })
            i = i + #url + 2
            handled = true
          end
        end
      end
    elseif c == "@" then
      local backend, value = rest:match("^@@([%w%-]+):(.-)@@")
      if backend then
        push({ type = "snippet", backend = backend, value = value })
        i = i + #backend + #value + 5
        handled = true
      end
    elseif c == "\\" then
      if rest:match("^\\\\%s*\n") or rest:match("^\\\\%s*$") then
        push({ type = "linebreak" })
        local ws = rest:match("^\\\\(%s*)")
        i = i + 2 + #ws
        handled = true
      elseif rest:match("^\\%(") then
        local e = s:find("\\)", i + 2, true)
        if e then
          push({ type = "latex", value = s:sub(i, e + 1) })
          i = e + 2
          handled = true
        end
      elseif rest:match("^\\%[") then
        local e = s:find("\\]", i + 2, true)
        if e then
          push({ type = "latex", value = s:sub(i, e + 1), display = true })
          i = e + 2
          handled = true
        end
      else
        local name, brace = rest:match("^\\(%a+)(%{?%}?)")
        if name and M.ENTITIES[name] and o.entities ~= false then
          push({ type = "entity", name = name })
          i = i + 1 + #name + (brace == "{}" and 2 or 0)
          handled = true
        elseif name and o.latex ~= false then
          local cmd = rest:match("^(\\%a+%b{})") or rest:match("^(\\%a+%b[]%b{})")
          if cmd then
            push({ type = "latex", value = cmd })
            i = i + #cmd
            handled = true
          end
        end
      end
    elseif c == "$" and o.latex ~= false then
      local prev = i > 1 and s:sub(i - 1, i - 1) or ""
      if rest:match("^%$%$") then
        local e = s:find("$$", i + 2, true)
        if e then
          push({ type = "latex", value = s:sub(i, e + 1), display = true })
          i = e + 2
          handled = true
        end
      elseif not prev:match("[%w%$]") then
        local e = s:find("$", i + 1, true)
        if e and e > i + 1 then
          local inner = s:sub(i + 1, e - 1)
          local after = s:sub(e + 1, e + 1)
          if
            not inner:match("^%s")
            and not inner:match("%s$")
            and not inner:find("\n\n", 1, true)
            and (after == "" or after:match("[%s%p]"))
          then
            push({ type = "latex", value = s:sub(i, e) })
            i = e + 1
            handled = true
          end
        end
      end
    elseif MARKERS[c] and o.emphasis ~= false then
      local prev = i > 1 and s:sub(i - 1, i - 1) or ""
      local nxt = s:sub(i + 1, i + 1)
      if (prev == "" or prev:match(PRE)) and nxt ~= "" and not nxt:match("%s") then
        local j = find_closing(s, i, c)
        if j then
          local inner = s:sub(i + 1, j - 1)
          local kind = MARKERS[c]
          if kind == "verbatim" or kind == "code" then
            push({ type = kind, value = inner })
          else
            push({ type = kind, children = M.parse_inline(inner, o) })
          end
          i = j + 1
          handled = true
        end
      end
    elseif (c == "s" or c == "c") and not (i > 1 and s:sub(i - 1, i - 1):match("[%w_]")) then
      -- inline src blocks src_lang[params]{body} and inline calls
      local lang, hdr, body = rest:match("^src_([%w%-%+]+)(%b[])(%b{})")
      if not lang then
        hdr = ""
        lang, body = rest:match("^src_([%w%-%+]+)(%b{})")
      end
      if lang then
        -- inline blocks export their results by default
        local exports = hdr:match(":exports%s+([%w%-]+)") or "results"
        if exports == "code" or exports == "both" then
          push({ type = "code", value = body:sub(2, -2), lang = lang })
        else
          flush()
        end
        i = i + 4 + #lang + #hdr + #body
        handled = true
      else
        local call = rest:match("^(call_[%w_%-]+%b[]%b()%b[])")
          or rest:match("^(call_[%w_%-]+%b()%b[])")
          or rest:match("^(call_[%w_%-]+%b[]%b())")
          or rest:match("^(call_[%w_%-]+%b())")
        if call then
          flush()
          i = i + #call
          handled = true
        end
      end
    elseif c == "h" or c == "f" or c == "m" then
      local url = rest:match("^(https?://[^%s<>%[%]\"]+)") or rest:match("^(ftp://[^%s<>%[%]\"]+)")
        or rest:match("^(mailto:[^%s<>%[%]\"]+)")
      local prev = i > 1 and s:sub(i - 1, i - 1) or ""
      if url and not prev:match("[%w]") then
        url = url:gsub("[%.,;:!%?%)]+$", "")
        push({ type = "link", path = url, raw = url, plain = true })
        i = i + #url
        handled = true
      end
    end
    if not handled and (c == "^" or c == "_") and o.sub ~= false then
      local prev = i > 1 and s:sub(i - 1, i - 1) or ""
      if prev ~= "" and not prev:match("%s") then
        local braced = rest:match("^.(%b{})")
        local kind = c == "^" and "sup" or "sub"
        if braced then
          push({ type = kind, children = M.parse_inline(braced:sub(2, -2), o) })
          i = i + 1 + #braced
          handled = true
        elseif o.sub ~= "{}" then
          local word = rest:match("^.([%w]+)")
          if word and prev:match("[%w%)%]]") then
            push({ type = kind, children = { { type = "text", value = word } } })
            i = i + 1 + #word
            handled = true
          end
        end
      end
    end
    if not handled and M._radios and #M._radios > 0 and not (i > 1 and s:sub(i - 1, i - 1):match("[%w_]")) then
      -- text matching a radio target links to it
      local low = rest:lower()
      for _, r in ipairs(M._radios) do
        local m = low:match(r.pat)
        if m and not rest:sub(#m + 1, #m + 1):match("[%w_]") then
          local text = rest:sub(1, #m)
          push({ type = "link", path = r.text, desc = { { type = "text", value = text } }, raw = text, radio = true })
          i = i + #m
          handled = true
          break
        end
      end
    end
    if not handled then
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  flush()
  return nodes
end

--- Plain text of inline nodes (for ids, TOC titles in text backends).
function M.plain(nodes)
  local out = {}
  for _, nd in ipairs(nodes or {}) do
    if nd.type == "text" or nd.type == "verbatim" or nd.type == "code" or nd.type == "timestamp" or nd.type == "latex" then
      out[#out + 1] = nd.value
    elseif nd.type == "link" then
      out[#out + 1] = nd.desc and M.plain(nd.desc) or nd.path
    elseif nd.type == "entity" then
      out[#out + 1] = M.ENTITIES[nd.name][2]
    elseif nd.type == "target" then
      out[#out + 1] = nd.value
    elseif nd.children then
      out[#out + 1] = M.plain(nd.children)
    elseif nd.type == "linebreak" then
      out[#out + 1] = " "
    end
  end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Preprocessing: #+INCLUDE and macros
---------------------------------------------------------------------------

--- Lines of the part of an org file selected by an #+INCLUDE search
--- option: `*Heading` or `#custom-id` (a subtree) or a `<<target>>` /
--- `#+NAME:` (the element).
local function include_search(content, search)
  local file = parser.parse(content)
  local hl
  local title = search:match("^%*%s*(.-)%s*$")
  local custom = search:match("^#(.+)$")
  if title then
    hl = file:find_headline(function(h)
      return h:plain_title() == title or h.title == title
    end)
  elseif custom then
    hl = file:find_by_custom_id(custom)
  end
  if hl then
    return vim.list_slice(content, hl.line, hl.end_line), true
  end
  for i, l in ipairs(content) do
    local nm = l:match("^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.-)%s*$")
    if nm == search then
      local j = i + 1
      if content[j] and content[j]:lower():match("^%s*#%+begin_") then
        while content[j] and not content[j]:lower():match("^%s*#%+end_") do
          j = j + 1
        end
      else
        while content[j + 1] and not content[j + 1]:match("^%s*$") do
          j = j + 1
        end
      end
      return vim.list_slice(content, i, math.min(j, #content)), false
    end
  end
  return nil
end

--- Shift headline levels of `content` so the shallowest one is `minlevel`.
local function shift_levels(content, minlevel)
  local min
  for _, l in ipairs(content) do
    local stars = l:match("^(%*+)%s")
    if stars and (not min or #stars < min) then
      min = #stars
    end
  end
  if not min or min == minlevel then
    return content
  end
  local out = {}
  for i, l in ipairs(content) do
    local stars, rest = l:match("^(%*+)(%s.*)$")
    out[i] = stars and (string.rep("*", math.max(1, #stars - min + minlevel)) .. rest) or l
  end
  return out
end

--- Drop the headline, planning and property drawer of an included subtree.
local function only_contents(content)
  local i = 2
  if content[i] and content[i]:match("^%s*[A-Z]+:%s*[<%[]") then
    i = i + 1
  end
  if content[i] and content[i]:match("^%s*:PROPERTIES:%s*$") then
    while content[i] and not content[i]:match("^%s*:END:%s*$") do
      i = i + 1
    end
    i = i + 1
  end
  return vim.list_slice(content, i)
end

--- Expand #+INCLUDE and #+SETUPFILE keywords.
local function expand_includes(lines, dir, depth)
  depth = depth or 0
  local utils = require("org.utils")
  local out = {}
  local level = 0
  for _, line in ipairs(lines) do
    local stars = line:match("^(%*+)%s")
    if stars then
      level = #stars
    end
    local spec = line:match("^%s*#%+[Ii][Nn][Cc][Ll][Uu][Dd][Ee]:%s*(.-)%s*$")
    local setup = not spec and line:match("^%s*#%+[Ss][Ee][Tt][Uu][Pp][Ff][Ii][Ll][Ee]:%s*(.-)%s*$")
    if setup and depth < 5 then
      -- only the in-buffer settings of a setup file are used
      local path = setup:match('^"(.-)"$') or setup
      local content = utils.readfile(utils.expand(path, dir))
      if content then
        for _, l in ipairs(expand_includes(content, vim.fn.fnamemodify(utils.expand(path, dir), ":h"), depth + 1)) do
          local low = l:lower()
          if l:match("^%s*#%+[%w_]+:") and not low:match("^%s*#%+begin_") and not low:match("^%s*#%+end_") then
            out[#out + 1] = l
          end
        end
      end
      out[#out + 1] = line
    elseif spec and depth < 5 then
      local path, rest = spec:match('^"(.-)"%s*(.*)$')
      if not path then
        path, rest = spec:match("^(%S+)%s*(.*)$")
      end
      local search
      if path then
        local p, s = path:match("^(.-)::(.*)$")
        if p then
          path, search = p, s
        end
      end
      local full = path and utils.expand(path, dir)
      local content = full and utils.readfile(full)
      if content then
        local range = rest:match(':lines%s+"(%d*%-%d*)"')
        if range then
          local a, b = range:match("^(%d*)%-(%d*)$")
          content = vim.list_slice(content, tonumber(a) or 1, tonumber(b) and (tonumber(b) - 1) or #content)
        end
        local subtree = false
        if search then
          content, subtree = include_search(content, search)
          content = content or {}
        end
        local kind, lang = rest:match("^(%a+)%s*(%S*)")
        if kind == "src" then
          out[#out + 1] = "#+begin_src " .. (lang or "")
          vim.list_extend(out, blocks.escape(content))
          out[#out + 1] = "#+end_src"
        elseif kind == "example" or kind == "export" then
          out[#out + 1] = "#+begin_" .. kind .. (lang ~= "" and (" " .. lang) or "")
          vim.list_extend(out, blocks.escape(content))
          out[#out + 1] = "#+end_" .. kind
        else
          if subtree and rest:match(":only%-contents%s+t") then
            content = only_contents(content)
          end
          content = expand_includes(content, vim.fn.fnamemodify(full, ":h"), depth + 1)
          -- like Emacs, headlines become children of the current one
          local minlevel = tonumber(rest:match(":minlevel%s+(%d+)")) or (level + 1)
          vim.list_extend(out, shift_levels(content, minlevel))
        end
      else
        out[#out + 1] = "# (missing include: " .. tostring(path) .. ")"
      end
    else
      out[#out + 1] = line
    end
  end
  return out
end

--- Split macro arguments on unescaped commas (`\,` is a literal comma).
local function macro_args(argstr)
  local args = {}
  local cur = {}
  local i = 1
  while i <= #argstr do
    local c = argstr:sub(i, i)
    if c == "\\" and argstr:sub(i + 1, i + 1) == "," then
      cur[#cur + 1] = ","
      i = i + 2
    else
      if c == "," then
        args[#args + 1] = vim.trim(table.concat(cur))
        cur = {}
      else
        cur[#cur + 1] = c
      end
      i = i + 1
    end
  end
  args[#args + 1] = vim.trim(table.concat(cur))
  return args
end

--- Find the end of a macro call `{{{name(args)}}}` starting at `s`.
local function macro_end(line, s)
  local e = line:find(")}}}", s, true)
  local plain = line:match("^{{{[%w_%-]+}}}", s)
  if plain and (not e or s + #plain - 1 < e) then
    return s + #plain - 1
  end
  return e and (e + 3) or nil
end

local function expand_macros(lines, settings, filename, file)
  local macros = {}
  for _, def in ipairs(settings.keywords.MACRO or {}) do
    local name, body = def:match("^(%S+)%s*(.*)$")
    if name then
      macros[name:lower()] = body
    end
  end
  local counters = {}
  local function kw(name)
    local v = settings.keywords[name:upper()]
    return v and table.concat(v, " ") or ""
  end
  local function format_date(value, fmt)
    local d = value and value ~= "" and require("org.date").parse(value)
    if d and fmt and fmt ~= "" then
      return d:strftime(fmt)
    end
    return value or ""
  end
  local builtin = {
    title = function()
      return kw("TITLE")
    end,
    author = function()
      return kw("AUTHOR")
    end,
    email = function()
      return kw("EMAIL")
    end,
    date = function(args)
      return format_date(kw("DATE"), args[1])
    end,
    time = function(args)
      return os.date(args[1] ~= "" and args[1] or "%Y-%m-%d")
    end,
    ["modification-time"] = function(args)
      local mtime = filename and vim.fn.getftime(filename) or -1
      return os.date(args[1] and args[1] ~= "" and args[1] or "%Y-%m-%d", mtime > 0 and mtime or os.time())
    end,
    ["input-file"] = function()
      return filename and vim.fn.fnamemodify(filename, ":t") or ""
    end,
    keyword = function(args)
      return kw(args[1] or "")
    end,
    results = function(args)
      return table.concat(args, ",")
    end,
    property = function(args, lnum)
      local name = args[1] or ""
      local hl = file and file:headline_at(lnum)
      if args[2] and args[2] ~= "" and file then
        local search = args[2]
        hl = file:find_by_custom_id((search:gsub("^#", ""))) or file:find_by_title((search:gsub("^%*%s*", "")))
          or file:find_by_id(search)
      end
      if not hl then
        return settings.properties and settings.properties[name:upper()] or ""
      end
      if name:upper() == "ITEM" then
        return hl:plain_title()
      end
      return hl:get_property(name:upper(), true) or hl:get_property(name, true) or ""
    end,
    n = function(args)
      local key = args[1] or ""
      local action = args[2] or ""
      if action == "-" then
        return tostring(counters[key] or 0)
      elseif tonumber(action) then
        counters[key] = tonumber(action)
      else
        counters[key] = (counters[key] or 0) + 1
      end
      return tostring(counters[key])
    end,
  }
  local function expand(line, lnum, depth)
    if depth > 10 or not line:find("{{{", 1, true) then
      return line
    end
    local out = {}
    local pos = 1
    local changed = false
    while true do
      local s = line:find("{{{", pos, true)
      if not s then
        out[#out + 1] = line:sub(pos)
        break
      end
      local e = macro_end(line, s)
      local call = e and line:sub(s + 3, e - 3)
      local name, argstr = nil, nil
      if call then
        name, argstr = call:match("^([%w_%-]+)%((.*)%)$")
        if not name then
          name = call:match("^([%w_%-]+)$")
        end
      end
      local replacement
      if name then
        local args = argstr and macro_args(argstr) or {}
        local lname = name:lower()
        if macros[lname] then
          replacement = macros[lname]:gsub("%$(%d)", function(d)
            if d == "0" then
              return argstr or ""
            end
            return args[tonumber(d)] or ""
          end)
        elseif builtin[lname] then
          replacement = builtin[lname](args, lnum)
        end
      end
      if replacement then
        out[#out + 1] = line:sub(pos, s - 1) .. replacement
        pos = e + 1
        changed = true
      else
        out[#out + 1] = line:sub(pos, s + 2)
        pos = s + 3
      end
    end
    local result = table.concat(out)
    if changed and result:find("{{{", 1, true) then
      return expand(result, lnum, depth + 1)
    end
    return result
  end
  local result = {}
  for i, line in ipairs(lines) do
    if line:match("^%s*#%+[Mm][Aa][Cc][Rr][Oo]:") then
      result[i] = line
    else
      result[i] = expand(line, i, 0)
    end
  end
  return result
end

---------------------------------------------------------------------------
-- Element parsing
---------------------------------------------------------------------------

local function indent_of(l)
  return #(l:match("^(%s*)"))
end

local function is_blank(l)
  return l:match("^%s*$") ~= nil
end

local ITEM_PAT = "^(%s*)([%-%+%*])%s+(.*)$"
local ITEM_ORD = "^(%s*)(%w+[%.%)])%s+(.*)$"

local function match_item(l)
  local ind, bullet, rest = l:match(ITEM_PAT)
  if ind and bullet == "*" and ind == "" then
    return nil
  end
  if not ind then
    ind, bullet, rest = l:match(ITEM_ORD)
    if ind and not (bullet:match("^%d+[%.%)]$") or bullet:match("^%a[%.%)]$")) then
      return nil
    end
  end
  if ind then
    return #ind, bullet, rest
  end
  -- bullet with empty content
  ind, bullet = l:match("^(%s*)([%-%+])$")
  if ind then
    return #ind, bullet, ""
  end
end

local function starts_element(l)
  return l:match("^%s*#%+") or l:match("^%s*|") or l:match("^%s*%-%-%-%-%-+%s*$") or l:match("^%s*:%s")
    or l:match("^%s*:$") or l:match("^%s*:[%w_%-]+:%s*$") or l:match("^%s*\\begin{") or match_item(l) ~= nil
    or l:match("^%s*#%s") or l:match("^%s*#$") or l:match("^%[fn:[^%]]+%]") or l:match("^%s*CLOCK:")
end

local function dedent(lines)
  local min
  for _, l in ipairs(lines) do
    if not is_blank(l) then
      local n = indent_of(l)
      min = (not min or n < min) and n or min
    end
  end
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = l:sub((min or 0) + 1)
  end
  return out
end

--- Line numbers (-n / +n) and coderefs (`(ref:name)`, removed with -r) of
--- a src or example block. Returns the lines and { [index] = label }.
local function code_lines(lines, switches, ctx)
  switches = switches or ""
  local pat = blocks.coderef_pattern(switches)
  local padded = " " .. switches .. " "
  local remove = padded:match("%s%-r%s") ~= nil
  local sign, val = padded:match("%s([%-%+])n%s+(%d*)")
  local start
  if sign == "-" then
    start = tonumber(val) or 1
  elseif sign == "+" then
    start = (ctx.doc.last_line_number or 0) + (tonumber(val) or 1)
  end
  local out, refs = {}, {}
  for i, l in ipairs(lines) do
    local label = l:match(pat)
    if label then
      refs[i] = label
      local number = (start or 1) + i - 1
      ctx.doc.coderefs[label] = (remove or start) and tostring(number) or label
      if remove then
        l = l:gsub(pat, "")
      end
    end
    out[i] = l
  end
  if start then
    local last = start + #out - 1
    ctx.doc.last_line_number = last
    local fmt = "%" .. #tostring(last) .. "d  "
    for i, l in ipairs(out) do
      out[i] = string.format(fmt, start + i - 1) .. l
    end
  end
  return out, next(refs) and refs or nil
end

--- Parse block elements from lines[s..e].
---@param ctx { o: table, file: org.File|nil, doc: table, base_line?: integer }
function M.parse_elements(lines, s, e, ctx)
  local o = ctx.o
  local out = {}
  local aff = {}
  local last_src = nil
  local i = s
  while i <= e do
    local l = lines[i]
    local lower = l:lower()
    if is_blank(l) then
      i = i + 1
    elseif lower:match("^%s*#%+begin_") then
      local btype = lower:match("^%s*#%+begin_(%S+)")
      local j = i + 1
      local endpat = "^%s*#%+end_" .. vim.pesc(btype) .. "%f[%W]"
      while j <= e and not lines[j]:lower():match(endpat) do
        j = j + 1
      end
      local inner = vim.list_slice(lines, i + 1, math.min(j, e + 1) - 1)
      local params = l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_%S+%s*(.*)$") or ""
      if btype == "src" then
        local lang = params:match("^(%S+)") or ""
        local rest = params:sub(#lang + 1)
        local switches, hparams = rest:match("^(.-)%s*(:.*)$")
        local fake = {
          start = (ctx.base_line or 0) + i,
          lang = lang,
          params = hparams or "",
          header_lines = aff.header or {},
        }
        local args = blocks.header_args(fake, ctx.file_for_args)
        local exports = args.exports or "code"
        local body = dedent(blocks.unescape(inner))
        local nw = args.noweb
        if ctx.all_lines and (nw == "yes" or nw == "strip-tangle" or nw == "strip-export") then
          local ok, expanded = pcall(
            require("org.babel").expand_noweb,
            ctx.all_lines,
            body,
            0,
            nw == "strip-export" and "strip" or nil,
            args,
            "export"
          )
          if ok then
            body = expanded
          end
        end
        local node = {
          type = "src",
          lang = lang,
          switches = switches or rest,
          affiliated = aff,
          exports = exports,
        }
        node.lines, node.coderefs = code_lines(body, node.switches, ctx)
        if exports == "code" or exports == "both" then
          out[#out + 1] = node
        end
        last_src = node
      elseif btype == "example" then
        local node = { type = "example", affiliated = aff, switches = params }
        node.lines, node.coderefs = code_lines(dedent(blocks.unescape(inner)), params, ctx)
        out[#out + 1] = node
      elseif btype == "quote" then
        out[#out + 1] = { type = "quote", children = M.parse_elements(inner, 1, #inner, ctx) }
      elseif btype == "center" then
        out[#out + 1] = { type = "center", children = M.parse_elements(inner, 1, #inner, ctx) }
      elseif btype == "verse" then
        local vl = {}
        for k, x in ipairs(inner) do
          vl[k] = M.parse_inline(x, o)
        end
        out[#out + 1] = { type = "verse", lines = vl }
      elseif btype == "export" then
        out[#out + 1] = { type = "export", backend = (params:match("^(%S+)") or ""):lower(), lines = inner }
      elseif btype == "comment" then
        -- dropped
      else
        out[#out + 1] = { type = "special", name = btype, children = M.parse_elements(inner, 1, #inner, ctx) }
      end
      if btype ~= "src" then
        last_src = nil
      end
      aff = {}
      i = j + 1
    elseif lower:match("^%s*#%+results") then
      local r_end = blocks.results_end(lines, i)
      r_end = math.min(r_end, e)
      local include = true
      if last_src then
        include = last_src.exports == "results" or last_src.exports == "both"
      end
      if include then
        local inner = vim.list_slice(lines, i + 1, r_end)
        -- unwrap RESULTS drawer
        if inner[1] and inner[1]:upper():match("^%s*:RESULTS:%s*$") then
          inner = vim.list_slice(inner, 2, #inner - 1)
        end
        vim.list_extend(out, M.parse_elements(inner, 1, #inner, ctx))
      end
      last_src = nil
      aff = {}
      i = r_end + 1
    elseif lower:match("^%s*#%+call:") then
      last_src = { exports = "results" }
      i = i + 1
    elseif lower:match("^%s*#%+[%w_]+:") then
      local key, value = l:match("^%s*#%+([%w_]+):%s*(.-)%s*$")
      key = key:upper()
      if key == "CAPTION" then
        aff.caption = M.parse_inline(value, o)
      elseif key == "NAME" then
        aff.name = value
      elseif key == "HEADER" then
        aff.header = aff.header or {}
        table.insert(aff.header, value)
      elseif key:match("^ATTR_") then
        aff.attr = aff.attr or {}
        aff.attr[key:sub(6):lower()] = value
      elseif key == "HTML" or key == "LATEX" or key == "ASCII" or key == "MD" or key == "BEAMER" then
        -- one-line export snippets: #+HTML: <br>
        out[#out + 1] = { type = "export", backend = key:lower(), lines = { value } }
      elseif key == "TOC" then
        local depth = value:match("headlines%s+(%d+)")
        out[#out + 1] = { type = "keyword_toc", depth = tonumber(depth) }
      end
      i = i + 1
    elseif l:match("^%s*#%s") or l:match("^%s*#$") then
      i = i + 1
    elseif l:match("^%s*:[%w_%-]+:%s*$") and not l:match("^%s*:%s") then
      local name = l:match("^%s*:([%w_%-]+):")
      local j = i + 1
      while j <= e and not lines[j]:match("^%s*:[Ee][Nn][Dd]:%s*$") do
        j = j + 1
      end
      if j > e then
        -- not a drawer: treat as paragraph text
        out[#out + 1] = { type = "paragraph", inline = M.parse_inline(vim.trim(l), o) }
        i = i + 1
      else
        local up = name:upper()
        local wanted
        if type(o.drawers) == "table" then
          -- d:("NOTES") exports only those, d:(not "LOGBOOK") all but those
          local listed = false
          for _, d in ipairs(o.drawers) do
            if d:upper() == up then
              listed = true
            end
          end
          wanted = listed ~= (o.drawers.negate == true)
        else
          wanted = o.drawers and up ~= "LOGBOOK"
        end
        if wanted and up ~= "PROPERTIES" then
          local inner = vim.list_slice(lines, i + 1, j - 1)
          vim.list_extend(out, M.parse_elements(inner, 1, #inner, ctx))
        end
        i = j + 1
      end
    elseif l:match("^%s*CLOCK:") then
      -- clock lines outside drawers are exported only with c:t
      if o.clocks then
        out[#out + 1] = { type = "paragraph", inline = { { type = "text", value = vim.trim(l) } } }
      end
      i = i + 1
    elseif l:match("^%s*|") then
      local rows = {}
      local header = 0
      local seen_hline = false
      while i <= e and lines[i]:match("^%s*|") do
        local tl = lines[i]
        if tl:match("^%s*|%-") then
          if not seen_hline and #rows > 0 then
            header = #rows
          end
          seen_hline = true
          rows[#rows + 1] = "hline"
        else
          local cells = require("org.table").split_cells(tl)
          -- skip alignment cookie rows
          local cookie = true
          for _, c in ipairs(cells) do
            if c ~= "" and not c:match("^<[lrc]?%d*>$") then
              cookie = false
            end
          end
          if not cookie then
            local parsed = {}
            for k, c in ipairs(cells) do
              parsed[k] = M.parse_inline(c, o)
            end
            rows[#rows + 1] = { cells = parsed, raw = cells }
          end
        end
        i = i + 1
      end
      while i <= e and lines[i]:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:") do
        i = i + 1
      end
      -- trim leading/trailing hlines
      while rows[1] == "hline" do
        table.remove(rows, 1)
        header = math.max(header - 1, 0)
      end
      while rows[#rows] == "hline" do
        table.remove(rows)
      end
      if o.tables ~= false then
        out[#out + 1] = { type = "table", rows = rows, header = header, affiliated = aff }
      end
      aff = {}
      last_src = nil
    elseif l:match("^%s*%-%-%-%-%-+%s*$") then
      out[#out + 1] = { type = "hr" }
      i = i + 1
    elseif l:match("^%s*:%s") or l:match("^%s*:$") then
      local fl = {}
      while i <= e and (lines[i]:match("^%s*:%s") or lines[i]:match("^%s*:$")) do
        fl[#fl + 1] = lines[i]:match("^%s*: (.*)$") or ""
        i = i + 1
      end
      out[#out + 1] = { type = "fixed", lines = fl }
    elseif l:match("^%s*\\begin{") then
      local env = l:match("^%s*\\begin{([^}]+)}")
      local j = i
      while j <= e and not lines[j]:find("\\end{" .. env .. "}", 1, true) do
        j = j + 1
      end
      out[#out + 1] = { type = "latex_env", lines = dedent(vim.list_slice(lines, i, math.min(j, e))) }
      i = j + 1
    elseif l:match("^%[fn:[^%]]+%]") then
      -- footnote definition
      local label, text = l:match("^%[fn:([^%]]+)%]%s*(.*)$")
      local j = i + 1
      local body = { text }
      local blanks = 0
      while j <= e do
        local x = lines[j]
        if x:match("^%[fn:[^%]]+%]") then
          break
        end
        if is_blank(x) then
          blanks = blanks + 1
          if blanks >= 2 then
            break
          end
        else
          blanks = 0
        end
        body[#body + 1] = x
        j = j + 1
      end
      ctx.doc.footnote_defs[label] = M.parse_elements(body, 1, #body, ctx)
      i = j
    elseif match_item(l) then
      local node, j = M.parse_list(lines, i, e, ctx)
      out[#out + 1] = node
      i = j
    else
      -- paragraph
      local pl = {}
      while i <= e do
        local x = lines[i]
        if is_blank(x) or (#pl > 0 and starts_element(x)) then
          break
        end
        pl[#pl + 1] = vim.trim(x)
        i = i + 1
      end
      if #pl == 0 then
        pl[1] = vim.trim(lines[i])
        i = i + 1
      end
      local text = table.concat(pl, "\n")
      if o.linebreaks == true then
        text = table.concat(pl, "\\\\\n")
      end
      out[#out + 1] = { type = "paragraph", inline = M.parse_inline(text, o), affiliated = aff }
      aff = {}
      last_src = nil
    end
  end
  return out
end

--- Parse a plain list starting at line i.
function M.parse_list(lines, i, e, ctx)
  local o = ctx.o
  local base = match_item(lines[i])
  local items = {}
  local kind
  while i <= e do
    local l = lines[i]
    if is_blank(l) then
      -- a blank line ends the list unless the next item continues it
      local j = i
      while j <= e and is_blank(lines[j]) do
        j = j + 1
      end
      if j - i >= 2 or j > e then
        i = j
        break
      end
      local ind = match_item(lines[j])
      if ind ~= base then
        break
      end
      i = j
      l = lines[i]
    end
    local ind, bullet, rest = match_item(l)
    if ind ~= base then
      break
    end
    local item = { bullet = bullet }
    local cb, after = rest:match("^%[([ xX%-])%]%s*(.*)$")
    if cb then
      item.checkbox = cb == " " and "off" or (cb == "-" and "trans" or "on")
      rest = after
    end
    local counter, after2 = rest:match("^%[@(%w+)%]%s*(.*)$")
    if counter then
      item.counter = counter
      rest = after2
    end
    if bullet:match("^%w") then
      kind = kind or "ordered"
    else
      local term, desc = rest:match("^(.-)%s+::%s*(.*)$")
      if not term then
        term, desc = rest:match("^(.-)%s+::$")
        desc = term and "" or nil
      end
      if term then
        kind = kind or "description"
        item.term = M.parse_inline(term, o)
        rest = desc
      else
        kind = kind or "unordered"
      end
    end
    local content = { rest }
    local j = i + 1
    while j <= e do
      local x = lines[j]
      if is_blank(x) then
        local k = j
        while k <= e and is_blank(lines[k]) do
          k = k + 1
        end
        if k - j >= 2 or k > e or indent_of(lines[k]) <= base then
          break
        end
        content[#content + 1] = ""
      elseif indent_of(x) <= base then
        break
      else
        content[#content + 1] = x
      end
      j = j + 1
    end
    local body = { content[1] }
    vim.list_extend(body, dedent(vim.list_slice(content, 2, #content)))
    item.children = M.parse_elements(body, 1, #body, ctx)
    items[#items + 1] = item
    i = j
  end
  return { type = "list", kind = kind or "unordered", items = items }, i
end

---------------------------------------------------------------------------
-- Document
---------------------------------------------------------------------------

local function slug(s)
  s = s:lower():gsub("[^%w%s%-]", ""):gsub("%s+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  return s ~= "" and s or "section"
end

--- Build the export document.
---@param lines string[]
---@param opts? { filename?: string, subtree_line?: integer, options?: table }
function M.parse(lines, opts)
  opts = opts or {}
  local dir = opts.filename and vim.fn.fnamemodify(opts.filename, ":p:h") or vim.fn.getcwd()
  lines = expand_includes(lines, dir)
  local file = parser.parse(lines, opts.filename)
  lines = expand_macros(lines, file.settings, opts.filename, file)
  file = parser.parse(lines, opts.filename)
  local settings = file.settings
  -- subtree export: EXPORT_OPTIONS and friends override the file keywords
  local root_hl = opts.subtree_line and file:headline_at(opts.subtree_line) or nil
  local root_props = root_hl and root_hl.properties or {}
  local o = M.options(settings, opts.options, root_props.EXPORT_OPTIONS and { root_props.EXPORT_OPTIONS } or nil)
  local kw = vim.deepcopy(settings.keywords)
  for _, k in ipairs({ "AUTHOR", "DATE", "EMAIL", "SUBTITLE", "DESCRIPTION", "KEYWORDS", "LANGUAGE" }) do
    if root_props["EXPORT_" .. k] then
      kw[k] = { root_props["EXPORT_" .. k] }
    end
  end
  -- radio targets turn matching text into links
  local radios = {}
  for _, l in ipairs(lines) do
    for r in l:gmatch("<<<([^<>]-)>>>") do
      -- words may be separated by any whitespace (also a line break)
      local words = vim.split(vim.trim(r):lower(), "%s+", { trimempty = true })
      for k, w in ipairs(words) do
        words[k] = vim.pesc(w)
      end
      if #words > 0 then
        radios[#radios + 1] = { text = r, pat = "^" .. table.concat(words, "%s+") }
      end
    end
  end
  table.sort(radios, function(a, b)
    return #a.text > #b.text
  end)
  M._radios = radios
  local doc = {
    title = settings.title,
    subtitle = kw.SUBTITLE and table.concat(kw.SUBTITLE, " ") or nil,
    author = kw.AUTHOR and table.concat(kw.AUTHOR, " ") or nil,
    email = kw.EMAIL and table.concat(kw.EMAIL, " ") or nil,
    date = kw.DATE and table.concat(kw.DATE, " ") or nil,
    language = kw.LANGUAGE and kw.LANGUAGE[1] or "en",
    description = kw.DESCRIPTION and table.concat(kw.DESCRIPTION, " ") or nil,
    keywords = kw.KEYWORDS and table.concat(kw.KEYWORDS, " ") or nil,
    html_head = kw.HTML_HEAD or {},
    latex_header = kw.LATEX_HEADER or {},
    latex_class = kw.LATEX_CLASS and kw.LATEX_CLASS[1] or nil,
    options = o,
    children = {},
    headlines = {},
    footnote_defs = {},
    ids = {}, -- lookup: kind:key -> anchor id
    coderefs = {}, -- coderef label -> text shown by links to it
    settings = settings,
  }
  local ctx = { o = o, doc = doc, file_for_args = file, all_lines = lines }
  -- footnote definitions may live anywhere (e.g. a "* Footnotes" section)
  do
    local fctx = { o = o, doc = doc, file_for_args = file }
    local i = 1
    while i <= #lines do
      if lines[i]:match("^%[fn:[^%]]+%]") then
        local j = i + 1
        while j <= #lines and not lines[j]:match("^%[fn:[^%]]+%]") and not lines[j]:match("^%*+%s")
          and not (lines[j]:match("^%s*$") and (lines[j + 1] or ""):match("^%s*$")) do
          j = j + 1
        end
        M.parse_elements(lines, i, j - 1, fctx)
        i = j
      else
        i = i + 1
      end
    end
  end
  local used_ids = {}
  local function unique(id)
    local base, n = id, 1
    while used_ids[id] do
      n = n + 1
      id = base .. "-" .. n
    end
    used_ids[id] = true
    return id
  end

  -- select tags present?
  local select_set, exclude_set = {}, {}
  for _, t in ipairs(o.select_tags or {}) do
    select_set[t] = true
  end
  for _, t in ipairs(o.exclude_tags or {}) do
    exclude_set[t] = true
  end
  local any_select = false
  for _, hl in ipairs(file.headlines) do
    for _, t in ipairs(hl.tags) do
      if select_set[t] then
        any_select = true
      end
    end
  end
  local function subtree_selected(hl)
    for _, t in ipairs(hl:get_tags()) do
      if select_set[t] then
        return true
      end
    end
    for _, c in ipairs(hl.children) do
      if subtree_selected(c) then
        return true
      end
    end
    return false
  end

  local function section_start(hl)
    local st = hl.line + 1
    if hl.planning_line then
      st = hl.planning_line + 1
    end
    if hl.properties_range then
      st = hl.properties_range[2] + 1
    end
    return st
  end

  local function build(hl, level_shift)
    if hl.commented then
      return nil
    end
    if hl.title == "Footnotes" and #hl.children == 0 then
      local only_defs = true
      for l = hl.line + 1, hl.body_end do
        if not (lines[l]:match("^%s*$") or lines[l]:match("^%[fn:") or lines[l]:match("^%s")) then
          only_defs = false
        end
      end
      if only_defs then
        return nil
      end
    end
    for _, t in ipairs(hl.tags) do
      if exclude_set[t] then
        return nil
      end
    end
    if any_select and not subtree_selected(hl) then
      return nil
    end
    -- tasks:nil / tasks:todo / tasks:done / tasks:("TODO" ...)
    if hl.todo and o.tasks ~= true then
      local keep = false
      if o.tasks == "todo" then
        keep = not hl:is_done()
      elseif o.tasks == "done" then
        keep = hl:is_done()
      elseif type(o.tasks) == "table" then
        keep = vim.tbl_contains(o.tasks, hl.todo)
      end
      if not keep then
        return nil
      end
    end
    if o.arch == false and hl:is_archived() then
      return nil
    end
    local title = hl.title
    if o.stat == false then
      title = vim.trim((title:gsub("%s*%[%d*/%d*%]", ""):gsub("%s*%[%d*%%%]", "")))
    end
    local level = hl.level - level_shift
    local node = {
      type = "headline",
      level = level,
      title = M.parse_inline(title, o),
      raw_title = hl:plain_title(),
      todo = hl.todo,
      todo_type = hl.todo and (hl:is_done() and "done" or "todo") or nil,
      priority = hl.priority,
      tags = vim.tbl_filter(function(t)
        return not select_set[t]
      end, hl.tags),
      properties = hl.properties,
      children = {},
      deep = level > (tonumber(o.H) or 3),
    }
    local custom = hl.properties.CUSTOM_ID
    node.id = unique(custom or slug(node.raw_title))
    doc.ids["title:" .. node.raw_title] = doc.ids["title:" .. node.raw_title] or node.id
    doc.ids["title:" .. hl.title] = doc.ids["title:" .. hl.title] or node.id
    if custom then
      doc.ids["custom:" .. custom] = node.id
    end
    if hl.properties.ID then
      doc.ids["id:" .. hl.properties.ID] = node.id
    end
    if o.planning and hl.planning_line then
      node.planning = vim.trim(lines[hl.planning_line])
    end
    doc.headlines[#doc.headlines + 1] = node
    if hl:is_archived() and o.arch ~= true then
      return node -- archived trees: headline only
    end
    local st = section_start(hl)
    ctx.base_line = 0
    if o.prop and hl.properties_range then
      -- prop:t / prop:("NAME" ...) exports the property drawer
      local plines = {}
      for l = hl.properties_range[1] + 1, hl.properties_range[2] - 1 do
        local k, v = lines[l]:match("^%s*:([^%s:]+):%s*(.-)%s*$")
        if k and (o.prop == true or (type(o.prop) == "table" and vim.tbl_contains(o.prop, k))) then
          plines[#plines + 1] = k .. ": " .. v
        end
      end
      if #plines > 0 then
        node.children[#node.children + 1] = { type = "example", lines = plines, properties = true }
      end
    end
    vim.list_extend(node.children, M.parse_elements(lines, st, hl.body_end, ctx))
    for _, c in ipairs(hl.children) do
      local cn = build(c, level_shift)
      if cn then
        node.children[#node.children + 1] = cn
      end
    end
    return node
  end

  if root_hl then
    doc.title = root_hl.properties.EXPORT_TITLE or root_hl:plain_title()
    doc.export_file_name = root_hl.properties.EXPORT_FILE_NAME
    local st = section_start(root_hl)
    vim.list_extend(doc.children, M.parse_elements(lines, st, root_hl.body_end, ctx))
    for _, c in ipairs(root_hl.children) do
      local cn = build(c, root_hl.level)
      if cn then
        doc.children[#doc.children + 1] = cn
      end
    end
  else
    doc.export_file_name = kw.EXPORT_FILE_NAME and kw.EXPORT_FILE_NAME[1] or nil
    vim.list_extend(doc.children, M.parse_elements(lines, 1, file.preamble_end, ctx))
    for _, hl in ipairs(file.children) do
      local cn = build(hl, 0)
      if cn then
        doc.children[#doc.children + 1] = cn
      end
    end
  end

  -- section numbers
  local num = o.num
  local max_num = type(num) == "number" and num or (num and math.huge or 0)
  local counters = {}
  local function number(nodes)
    for _, nd in ipairs(nodes) do
      if nd.type == "headline" then
        if nd.level <= max_num and not nd.deep and not (nd.properties.UNNUMBERED and nd.properties.UNNUMBERED ~= "nil") then
          counters[nd.level] = (counters[nd.level] or 0) + 1
          for l = nd.level + 1, #counters do
            counters[l] = nil
          end
          local parts = {}
          for l = 1, nd.level do
            parts[l] = counters[l] or 0
          end
          nd.number = parts
        end
        number(nd.children)
      end
    end
  end
  number(doc.children)

  -- named elements & targets
  local function scan(nodes)
    for _, nd in ipairs(nodes) do
      if nd.affiliated and nd.affiliated.name then
        local id = unique(slug(nd.affiliated.name))
        nd.id = id
        doc.ids["name:" .. nd.affiliated.name] = id
      end
      if nd.inline then
        for _, inl in ipairs(nd.inline) do
          if inl.type == "target" then
            local id = doc.ids["target:" .. inl.value] or unique("target-" .. slug(inl.value))
            inl.id = id
            doc.ids["target:" .. inl.value] = id
          end
        end
      end
      if nd.coderefs then
        for _, label in pairs(nd.coderefs) do
          doc.ids["coderef:" .. label] = "coderef-" .. slug(label)
        end
      end
      if nd.children then
        scan(nd.children)
      end
      if nd.items then
        for _, it in ipairs(nd.items) do
          scan(it.children)
        end
      end
    end
  end
  scan(doc.children)
  -- links to coderefs show the line number (-n / -r) or the label
  local function fix_links(nodes)
    for _, inl in ipairs(nodes or {}) do
      if inl.type == "link" and not inl.desc then
        local label = inl.path:match("^%((.+)%)$")
        if label and doc.coderefs[label] then
          inl.desc = { { type = "text", value = doc.coderefs[label] } }
        end
      end
      if inl.children then
        fix_links(inl.children)
      end
    end
  end
  local function walk(nodes)
    for _, nd in ipairs(nodes or {}) do
      fix_links(nd.inline)
      if nd.children then
        walk(nd.children)
      end
      for _, it in ipairs(nd.items or {}) do
        walk(it.children)
      end
    end
  end
  if next(doc.coderefs) then
    walk(doc.children)
  end
  M._radios = nil
  return doc
end

--- Resolve an internal link path to an anchor id (or nil).
function M.resolve_internal(doc, path)
  local custom = path:match("^#(.+)$")
  if custom then
    return doc.ids["custom:" .. custom]
  end
  local title = path:match("^%*%s*(.+)$")
  if title then
    return doc.ids["title:" .. title]
  end
  local id = path:match("^id:(.+)$")
  if id then
    return doc.ids["id:" .. id]
  end
  local coderef = path:match("^%((.+)%)$")
  if coderef then
    return doc.ids["coderef:" .. coderef]
  end
  return doc.ids["target:" .. path] or doc.ids["name:" .. path] or doc.ids["title:" .. path]
end

--- Classify a link path. Returns kind, target:
---   "url", url | "internal", anchor | "file", path, search | "image", path | "other", path
local IMAGE = { png = true, jpg = true, jpeg = true, gif = true, svg = true, webp = true, bmp = true }
function M.classify_link(doc, path)
  local abbrevs = vim.tbl_extend(
    "force",
    require("org.config").opts.links and require("org.config").opts.links.abbreviations or {},
    doc.settings.link_abbrevs or {}
  )
  local abbr, tag = path:match("^([%w_%-]+):(.*)$")
  if abbr and abbrevs[abbr] then
    local tpl = abbrevs[abbr]
    if type(tpl) == "function" then
      path = tpl(tag)
    elseif tpl:find("%s", 1, true) then
      path = tpl:gsub("%%s", (tag:gsub("%%", "%%%%")))
    else
      path = tpl .. tag
    end
  end
  if path:match("^https?://") or path:match("^ftp://") or path:match("^mailto:") or path:match("^doi:") then
    if path:match("^doi:") then
      path = "https://doi.org/" .. path:sub(5)
    end
    local ext = path:match("%.(%w+)$")
    if ext and IMAGE[ext:lower()] then
      return "image", path
    end
    return "url", path
  end
  local fpath = path:match("^file:(.*)$") or path:match("^attachment:(.*)$")
  if not fpath and (path:match("^[%./~]") and not path:match("^%*")) then
    fpath = path
  end
  if fpath then
    local p, search = fpath:match("^(.-)::(.*)$")
    p = p or fpath
    local ext = p:match("%.(%w+)$")
    if ext and IMAGE[ext:lower()] then
      return "image", p
    end
    return "file", p, search
  end
  local anchor = M.resolve_internal(doc, path)
  if anchor then
    return "internal", anchor
  end
  if path:match("^id:") or path:match("^#") or path:match("^%*") then
    return "broken", path
  end
  if path:match("^%a[%w+.%-]*:") then
    return "other", path
  end
  return "broken", path
end

M.slug = slug

return M
