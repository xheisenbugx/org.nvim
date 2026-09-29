---@mod org.export.csl.proc The CSL processor
--- (port of citeproc-proc.el, citeproc-itemdata.el, citeproc-disamb.el,
--- citeproc-sort.el, citeproc-cite.el, citeproc-subbibs.el and the public
--- API of citeproc.el)

local U = require("org.export.csl.util")
local R = require("org.export.csl.regex")
local rt = require("org.export.csl.rt")
local S = require("org.export.csl.style")
local E = require("org.export.csl.render")
local F = require("org.export.csl.formatters")

local M = {}

local aget, acons = U.aget, U.acons

--- Emacs nil inside a list is stored as false.
local function nf(x)
  if x == nil then
    return false
  end
  return x
end

--- setf (alist-get k al) on a table that must keep its identity.
local function aset_in_place(al, k, v)
  local p = U.assoc(al, k)
  if p then
    p[2] = v
  else
    table.insert(al, 1, { k, v })
  end
end

---------------------------------------------------------------------------
-- Item data
---------------------------------------------------------------------------

local function itd_getvar(itd, var)
  return aget(itd.varvals, var)
end

--- citeproc-itd-setvar (a nil value removes the variable)
local function itd_setvar(itd, var, val)
  if val == nil then
    local out = {}
    local removed = false
    for _, p in ipairs(itd.varvals) do
      if not removed and type(p) == "table" and p[1] == var then
        removed = true
      else
        out[#out + 1] = p
      end
    end
    itd.varvals = out
  else
    local p = U.assoc(itd.varvals, var)
    if p then
      p[2] = val
    else
      itd.varvals = acons(var, val, itd.varvals)
    end
  end
  itd.rc_uptodate = false
end

local function itd_rt_cite(itd, style)
  if itd.rc_uptodate then
    return itd.rawcite
  end
  local rc = E.render_varlist_in_rt(acons("position", itd.disamb_pos, itd.varvals), style, "cite", "display", "no-links", true)
  itd.rawcite = rc
  itd.rc_uptodate = true
  return rc
end

local function itd_plain_cite(itd, style)
  return rt.to_plain(itd_rt_cite(itd, style))
end

local function itd_update_disamb_pos(itd, pos)
  local old = itd.disamb_pos
  if old ~= "subsequent" then
    local new
    if pos == "first" then
      new = "first"
    elseif pos == "ibid" or pos == "ibid-with-locator" then
      new = "ibid"
    else
      new = "subsequent"
    end
    if old == nil or old == "first" then
      itd.disamb_pos = new
    elseif new == "subsequent" then
      itd.disamb_pos = "subsequent"
    else
      itd.disamb_pos = "ibid"
    end
  end
end

---------------------------------------------------------------------------
-- Internalizing items
---------------------------------------------------------------------------

local function smart_apostrophes(s)
  return U.replace("'", "ʼ", U.replace("’", "ʼ", s))
end

--- citeproc-s-smart-quotes
local function smart_quotes(s, oq, cq)
  local cps = U.codepoints(s)
  local out = {}
  for i, c in ipairs(cps) do
    if c == 34 then
      local nxt = cps[i + 1]
      if nxt and U.is_word_cp(nxt) then
        out[#out + 1] = oq or ""
      else
        out[#out + 1] = cq or ""
      end
    else
      out[#out + 1] = U.char(c)
    end
  end
  return table.concat(out)
end

local function internalize_name(name, proc)
  local sorted = U.stable_sort(name, function(x, y)
    return x[1] < y[1]
  end)
  local key = vim.inspect(sorted)
  local id = proc.names[key]
  if id == nil then
    id = proc.names_count
    proc.names[key] = id
    proc.names_count = proc.names_count + 1
  end
  return acons("name-id", id, sorted)
end

local function parse_csl_json_name(rep)
  local literal = aget(rep, "literal")
  if literal then
    return { { "family", smart_apostrophes(literal) } }
  end
  local out = {}
  for _, p in ipairs(rep) do
    if p[1] ~= "isInstitution" then
      local v = p[2]
      out[#out + 1] = { p[1], type(v) == "string" and smart_apostrophes(v) or v }
    end
  end
  return out
end

local function parse_date_rep(rep)
  if type(rep) ~= "table" then
    return nil
  end
  local parts = aget(rep, "date-parts")
  if type(parts) ~= "table" then
    return nil
  end
  local out = {}
  for _, dp in ipairs(parts) do
    local nums = {}
    for i = 1, 3 do
      local x = dp[i]
      if type(x) == "string" then
        x = U.to_number(x)
      end
      nums[i] = x
    end
    out[#out + 1] = {
      year = nums[1],
      month = nums[2],
      day = nums[3],
      season = aget(rep, "season"),
      circa = aget(rep, "circa"),
    }
  end
  if #out == 0 then
    return nil
  end
  return out
end
M.parse_date_rep = parse_date_rep

local function parse_var_val(rep, var, proc)
  if rt.NAME_VAR_SET[var] then
    local out = {}
    for _, it in ipairs(rep or {}) do
      out[#out + 1] = internalize_name(parse_csl_json_name(it), proc)
    end
    if #out == 0 then
      return nil
    end
    return out
  elseif rt.DATE_VAR_SET[var] then
    return parse_date_rep(rep)
  elseif rt.NUMBER_VAR_SET[var] or var == "id" then
    return U.num_str(rep)
  elseif type(rep) == "string" then
    local r = rt.from_str(smart_apostrophes(rep))
    if rep:find('"', 1, true) then
      local terms = proc.style.terms
      local oq = S.term_text_from_terms("open-quote", terms)
      local cq = S.term_text_from_terms("close-quote", terms)
      return rt.change_case(r, function(x)
        return smart_quotes(x, oq, cq)
      end)
    end
    return r
  end
  return rep
end

local NONSTD = { shortTitle = "title-short", journalAbbreviation = "container-title-short" }

local function internalize_item(proc, item)
  local label, page_first
  local result = {}
  for _, it in ipairs(item) do
    local var = NONSTD[it[1]] or it[1]
    local value = parse_var_val(it[2], var, proc)
    if var == "page" and type(value) == "string" then
      local m = R.match("[[:digit:]]+", value)
      if m then
        page_first = m[0]
      end
    elseif var == "label" then
      label = true
    end
    result[#result + 1] = { var, value }
  end
  if page_first then
    result = acons("page-first", page_first, result)
  end
  if not label then
    result = acons("label", "page", result)
  end
  if aget(result, "editor-translator") == nil and aget(result, "editor") and aget(result, "translator") then
    -- (alist-get 'name-id EDITOR) is nil for both name lists, so they
    -- always compare equal in citeproc-el
    result = acons("editor-translator", aget(result, "editor"), result)
  end
  return result
end

local function put_item(proc, item, itemid, uncited)
  local itd = { varvals = internalize_item(proc, item), uncited = uncited }
  proc.itemdata:put(itemid, itd)
  itd_setvar(itd, "citation-number", U.num_str(proc.itemdata:count()))
  proc.finalized = false
  return itd
end

--- citeproc-proc-put-item-by-id
function M.put_item_by_id(proc, itemid)
  local received = proc.getter({ itemid })
  local item = received[1] and received[1][2]
  return put_item(proc, item or { { "unprocessed-with-id", itemid } }, itemid)
end

local function put_items_by_id(proc, itemids)
  local received = proc.getter(itemids)
  for _, id in ipairs(itemids) do
    local item = aget(received, id)
    put_item(proc, item or { { "unprocessed-with-id", id } }, id)
  end
end

local function process_uncited(proc)
  if #proc.uncited == 0 then
    return
  end
  local all = {}
  for _, l in ipairs(proc.uncited) do
    for _, id in ipairs(l) do
      all[#all + 1] = id
    end
  end
  -- cl-delete-duplicates keeps the last occurrence
  local ids, seen = {}, {}
  for i = #all, 1, -1 do
    if not seen[all[i]] then
      seen[all[i]] = true
      table.insert(ids, 1, all[i])
    end
  end
  if seen["*"] then
    ids = proc.getter("itemids")
  end
  local new_ids = {}
  for _, id in ipairs(ids) do
    if proc.itemdata:get(id) == nil then
      new_ids[#new_ids + 1] = id
    end
  end
  local received = proc.getter(new_ids)
  for _, id in ipairs(new_ids) do
    put_item(proc, aget(received, id) or { { "unprocessed-with-id", id } }, id, true)
  end
end

---------------------------------------------------------------------------
-- Disambiguation
---------------------------------------------------------------------------

local function inc_disamb_level(key, itd, ty)
  local p = U.assoc(itd.varvals, ty)
  if p and p[2] then
    local inner = p[2]
    local cur = aget(inner, key)
    local new = cur and cur + 1 or 1
    local ip = U.assoc(inner, key)
    if ip then
      ip[2] = new
    else
      p[2] = acons(key, new, inner)
    end
  else
    itd.varvals = acons(ty, { { key, 1 } }, itd.varvals)
  end
  itd.rc_uptodate = false
end

local function index_of(list, x)
  for i, v in ipairs(list) do
    if v == x then
      return i
    end
  end
end

local function memq_tail(list, x)
  local i = index_of(list, x)
  if not i then
    return {}
  end
  return vim.list_slice(list, i)
end

local function itd_add_name(itd, style)
  local vars = rt.rendered_name_vars(itd_rt_cite(itd, style))
  local cite = itd_plain_cite(itd, style)
  local levels = aget(itd.varvals, "add-names")
  local remaining = (levels and levels[1]) and memq_tail(vars, levels[1][1]) or vars
  local success = false
  local i = 1
  while not success and i <= #remaining do
    inc_disamb_level(remaining[i], itd, "add-names")
    if cite == itd_plain_cite(itd, style) then
      i = i + 1
    else
      success = true
    end
  end
  return success
end

local function itd_add_given(itd, style, first_step)
  local nids = rt.rendered_name_ids(itd_rt_cite(itd, style))
  local cite = itd_plain_cite(itd, style)
  local levels = aget(itd.varvals, "show-given-names")
  local remaining = (levels and levels[1]) and memq_tail(nids, levels[1][1]) or nids
  local success = false
  local i = 1
  while not success and i <= #remaining do
    local nid = remaining[i]
    local had = U.assoc(itd.varvals, "show-given-names")
    local cur_levels = aget(itd.varvals, "show-given-names")
    local cur = aget(cur_levels, nid)
    if cur and cur >= 2 then
      i = i + 1
    else
      inc_disamb_level(nid, itd, "show-given-names")
      if cite ~= itd_plain_cite(itd, style) then
        success = true
        if not (first_step or cur) then
          if had then
            local ls = had[2] or {}
            local n = {}
            if ls[1] then
              n[1] = ls[1]
            end
            for k = 3, #ls do
              n[#n + 1] = ls[k]
            end
            had[2] = n
          end
          itd.rc_uptodate = false
        end
      end
    end
  end
  return success
end

local function itd_addgiven_with_addname(itd, style, first_step)
  local gn = aget(itd.varvals, "show-given-names")
  if not first_step and gn and gn[1] and gn[1][2] == 1 and itd_add_given(itd, style) then
    return true
  end
  local success = false
  local remaining = true
  while not success and remaining do
    local nids = rt.rendered_name_ids(itd_rt_cite(itd, style))
    if itd_add_name(itd, style) then
      local new_nids = rt.rendered_name_ids(itd_rt_cite(itd, style))
      local old = {}
      for _, x in ipairs(nids) do
        old[x] = true
      end
      local new_nid
      for _, x in ipairs(new_nids) do
        if not old[x] then
          new_nid = x
          break
        end
      end
      if first_step then
        local p = U.assoc(itd.varvals, "show-given-names")
        if p then
          local ip = U.assoc(p[2], new_nid)
          if ip then
            ip[2] = 0
          else
            p[2] = acons(new_nid, 0, p[2])
          end
        else
          itd.varvals = acons("show-given-names", { { new_nid, 0 } }, itd.varvals)
        end
      end
      if itd_add_given(itd, style, first_step) then
        success = true
      end
    else
      remaining = false
    end
  end
  return success
end

local function different_cites_p(itds, style)
  local first = itd_plain_cite(itds[1], style)
  for i = 2, #itds do
    if itd_plain_cite(itds[i], style) ~= first then
      return true
    end
  end
  return false
end

local function disamb_settings(itds)
  local out = {}
  for i, it in ipairs(itds) do
    out[i] = { vim.deepcopy(itd_getvar(it, "add-names")), vim.deepcopy(itd_getvar(it, "show-given-names")) }
  end
  return out
end

local function restore_settings(itds, settings)
  for i, itd in ipairs(itds) do
    itd_setvar(itd, "add-names", settings[i][1])
    itd_setvar(itd, "show-given-names", settings[i][2])
  end
end

local function with_method(itds, style, fn)
  local orig = disamb_settings(itds)
  local success = false
  local first_step = true
  while not success do
    local all = true
    for _, it in ipairs(itds) do
      if not fn(it, style, first_step) then
        all = false
        break
      end
    end
    if not all then
      break
    end
    first_step = false
    if different_cites_p(itds, style) then
      success = true
    end
  end
  if not success then
    restore_settings(itds, orig)
  end
  return success
end

local function num_to_yearsuffix(n)
  if n < 26 then
    return string.char(97 + n)
  elseif n < 702 then
    local rem = n % 26
    local d = (n - rem) / 26
    return string.char(96 + d) .. string.char(97 + rem)
  end
  error("Number too large to convert into a year-suffix", 0)
end

local function citnum(itd)
  return U.to_number(itd_getvar(itd, "citation-number"))
end

local function add_yearsuffix(itds)
  local sorted = U.stable_sort(itds, function(a, b)
    return citnum(a) < citnum(b)
  end)
  for i, it in ipairs(sorted) do
    itd_setvar(it, "year-suffix", num_to_yearsuffix(i - 1))
    it.rc_uptodate = false
  end
  return true
end

local function disamb_amb_itds(itds, style, name, given, yearsuff)
  if name and with_method(itds, style, itd_add_name) then
    return true
  end
  if given and with_method(itds, style, itd_add_given) then
    return true
  end
  if name and given and with_method(itds, style, itd_addgiven_with_addname) then
    return true
  end
  for _, it in ipairs(itds) do
    itd_setvar(it, "disambiguate", true)
  end
  if different_cites_p(itds, style) then
    return true
  end
  if yearsuff then
    add_yearsuffix(itds)
    return different_cites_p(itds, style)
  end
  return false
end

local function amb_itds(itds, style)
  local sorted = U.stable_sort(itds, function(x, y)
    return itd_plain_cite(x, style) < itd_plain_cite(y, style)
  end)
  local result = {}
  local act = sorted[1]
  local act_list = { act }
  local ambig = false
  for i = 2, #sorted do
    local nxt = sorted[i]
    if itd_plain_cite(act, style) == itd_plain_cite(nxt, style) then
      table.insert(act_list, 1, nxt)
      ambig = true
    else
      if ambig then
        table.insert(result, 1, act_list)
      end
      act_list = { nxt }
      act = nxt
      ambig = false
    end
  end
  if ambig then
    table.insert(result, 1, act_list)
  end
  return result
end

local function disamb_itds(itds, style, name, given, yearsuff)
  if #itds == 0 then
    return
  end
  local amb = amb_itds(itds, style)
  while #amb > 0 do
    local act = table.remove(amb, 1)
    disamb_amb_itds(act, style, name, given, yearsuff)
    if different_cites_p(act, style) then
      local new = amb_itds(act, style)
      for i = #new, 1, -1 do
        table.insert(amb, 1, new[i])
      end
    end
  end
end

local function proc_disamb(proc)
  local opts = proc.style.cite_opts
  disamb_itds(
    proc.itemdata:values(),
    proc.style,
    aget(opts, "disambiguate-add-names") == "true",
    aget(opts, "disambiguate-add-givenname") == "true",
    aget(opts, "disambiguate-add-year-suffix") == "true"
  )
end

---------------------------------------------------------------------------
-- Sub-bibliographies
---------------------------------------------------------------------------

local function clean_ws(s)
  return U.trim((s:gsub("[%s]+", " ")))
end

local function sb_match_p(vv, filter)
  local csl_type = aget(vv, "type")
  local ty = aget(vv, "blt-type") or csl_type
  local keyword = aget(vv, "keyword")
  local keywords = {}
  if type(keyword) == "string" then
    for _, k in ipairs(R.split(keyword, "[,;]", true)) do
      keywords[clean_ws(k)] = true
    end
  end
  for _, it in ipairs(filter) do
    local k, v = it[1], it[2]
    local ok
    if k == "type" then
      ok = ty == v
    elseif k == "nottype" then
      ok = ty ~= v
    elseif k == "keyword" then
      ok = keywords[v] ~= nil
    elseif k == "notkeyword" then
      ok = keywords[v] == nil
    elseif k == "filter" then
      local fn = type(v) == "function" and v or nil
      if not fn then
        error(string.format("Unsupported Citeproc filter function `%s'", tostring(v)), 0)
      end
      ok = fn(vv)
    elseif k == "csltype" then
      ok = csl_type == v
    elseif k == "notcsltype" then
      ok = csl_type ~= v
    else
      error(string.format("Unsupported Citeproc filter keyword `%s'", tostring(k)), 0)
    end
    if not ok then
      return false
    end
  end
  return true
end

local function filtered_bib_p(proc)
  local f = proc.bib_filters
  return f ~= nil and #f > 0 and not (#f == 1 and #f[1] == 0)
end

local function sb_add_subbib_info(proc)
  if not filtered_bib_p(proc) then
    return
  end
  proc.itemdata:each(function(_, itd)
    local nos = {}
    for i, f in ipairs(proc.bib_filters) do
      if sb_match_p(itd.varvals, f) then
        nos[#nos + 1] = i - 1
      end
    end
    itd.subbib_nos = nos
  end)
end

local function sb_prune_unrendered(proc)
  if not filtered_bib_p(proc) then
    return
  end
  proc.itemdata:each(function(id, itd)
    if itd.uncited and (not itd.subbib_nos or #itd.subbib_nos == 0) then
      proc.itemdata:remove(id)
    end
  end)
end

---------------------------------------------------------------------------
-- Sorting items
---------------------------------------------------------------------------

local function sort_on_citnum(itds)
  return U.stable_sort(itds, function(x, y)
    return citnum(x) < citnum(y)
  end)
end

local function sort_itds(itds, orders)
  return U.stable_sort(itds, function(x, y)
    return E.compare_keylists(x.sort_key, y.sort_key, orders)
  end)
end

local function update_sortkeys(proc)
  proc.itemdata:each(function(_, itd)
    itd.sort_key = E.render_keys(proc.style, itd.varvals, "bib")
  end)
end

local function proc_sort_itds(proc)
  local sorted_bib = proc.style.bib_sort
  local filtered = filtered_bib_p(proc)
  if sorted_bib or filtered then
    local itds = sort_on_citnum(proc.itemdata:values())
    if sorted_bib then
      itds = sort_itds(itds, proc.style.bib_sort_orders)
    end
    if filtered then
      itds = U.stable_sort(itds, function(a, b)
        local i1 = a.subbib_nos and a.subbib_nos[1]
        local i2 = b.subbib_nos and b.subbib_nos[1]
        return i1 ~= nil and (i2 == nil or i1 < i2)
      end)
    end
    for i, it in ipairs(itds) do
      itd_setvar(it, "citation-number", U.num_str(i))
    end
  end
end

---------------------------------------------------------------------------
-- Cites
---------------------------------------------------------------------------

local MODE_REP = {
  textual = { { "suppress-author", true } },
  ["suppress-author"] = { { "suppress-author", true } },
  ["author-only"] = { { "stop-rendering-at", "names" } },
  ["year-only"] = { { "stop-rendering-at", "issued" } },
  ["title-only"] = { { "stop-rendering-at", "title" }, { "bib-entry", true }, { "use-short-title", true } },
  ["bib-entry"] = { { "bib-entry", true } },
  ["locator-only"] = { { "locator-only", true } },
}

local CITE_VARS = U.set({
  "label",
  "locator",
  "suppress-author",
  "suppress-date",
  "stop-rendering-at",
  "position",
  "near-note",
  "first-reference-note-number",
  "ignore-et-al",
  "bib-entry",
  "locator-only",
  "use-short-title",
  "locator-extra",
  "locator-date",
})

--- citeproc-cite--varlist
local function cite_varlist(cite)
  local itd = aget(cite, "itd")
  local out = {}
  for _, p in ipairs(cite) do
    if type(p) == "table" and CITE_VARS[p[1]] then
      out[#out + 1] = p
    end
  end
  for _, p in ipairs(itd and itd.varvals or {}) do
    out[#out + 1] = p
  end
  return out
end

--- citeproc-cite--internalize-locator
local function internalize_locator(cite)
  local locator = aget(cite, "locator")
  if type(locator) == "string" then
    local pos = locator:find("|", 1, true)
    if pos then
      aset_in_place(cite, "locator", locator:sub(1, pos - 1))
      local s = locator:sub(pos + 1)
      local date, extra
      if not s:match("^%d%d%d%d%-%d%d%-%d%d") then
        extra = not U.blank_str(s) and s or nil
      else
        date = parse_date_rep(require("org.export.csl.bib").blt_to_csl_date(s:sub(1, 10)))
        local rest = s:sub(11)
        if not U.blank_str(rest) then
          extra = rest
        end
      end
      if date then
        table.insert(cite, 1, { "locator-date", date })
      end
      if extra then
        table.insert(cite, 1, { "locator-extra", extra })
      end
    end
  end
  return cite
end

--- citeproc-cite--render
local function cite_render(cite, style, internal_links)
  local suff = aget(cite, "suffix")
  local pref = aget(cite, "prefix")
  local bib_entry = aget(cite, "bib-entry")
  local locator_only = aget(cite, "locator-only")
  local stop = aget(cite, "stop-rendering-at")
  local rt_pref = rt.from_str(pref)
  local plain_pref = rt.to_plain(rt_pref)
  local rt_suff = rt.from_str(suff)
  local plain_suff = rt.to_plain(rt_suff)
  local mode = bib_entry and "bib" or "cite"
  local varlist = cite_varlist(cite)
  if mode == "bib" and not stop then
    varlist = acons("citation-number", nil, varlist)
  end
  local rendered = E.render_varlist_in_rt(
    varlist,
    style,
    mode,
    "display",
    mode == "bib" and "no-links" or internal_links,
    stop == "title"
  )
  if locator_only then
    rendered = rt.locator_w_label(rendered)
  end
  if stop == "title" then
    local attr = E.int_link_attrval(style, internal_links, "cite", aget(varlist, "position"))
    if attr and type(rendered) == "table" then
      local a = {}
      for _, p in ipairs(rendered[1]) do
        a[#a + 1] = p
      end
      a[#a + 1] = { attr, aget(varlist, "citation-number") }
      rendered[1] = a
    end
  end
  local result = {}
  if U.present(plain_pref) then
    result[#result + 1] = rt_pref
    if U.aref(plain_pref, -1) ~= 32 then
      result[#result + 1] = " "
    end
  end
  result[#result + 1] = nf(rendered)
  if U.present(plain_suff) then
    local c = U.aref(plain_suff, 0)
    if c ~= 44 and c ~= 32 then
      result[#result + 1] = " "
    end
    result[#result + 1] = rt.from_str(suff)
  end
  result.n = #result
  return E.join_formatted(nil, result, nil)
end

local function render_cite_or_group(c, style, links, top_dl, gr_dl, ys_dl, ac_dl)
  if c.kind == "top" or c.kind == "group" or c.kind == "year-suffix-collapsed" then
    local delimiter = c.kind == "top" and top_dl or (c.kind == "group" and gr_dl or ys_dl)
    local out = { {} }
    for _, it in ipairs(c) do
      out[#out + 1] = render_cite_or_group(it, style, links, top_dl, gr_dl, ys_dl, ac_dl) or false
      if it.kind == "group" or it.kind == "year-suffix-collapsed" then
        out[#out + 1] = nf(ac_dl)
      else
        out[#out + 1] = nf(delimiter)
      end
    end
    if #out > 1 then
      table.remove(out)
    end
    return out
  elseif c.kind == "range" then
    return { {}, cite_render(c[1], style, links) or false, "–", cite_render(c[2], style, links) or false }
  end
  return cite_render(c, style, links)
end

--- citeproc-citation--render
local function citation_render(c, proc, links)
  local style = proc.style
  local piq = aget(style.locale_opts, "punctuation-in-quote") == "true"
  local cites = c.cites
  local cite_attrs = style.cite_layout_attrs or {}
  local layout_dl = aget(cite_attrs, "delimiter")
  if c.suppress_affixes then
    cite_attrs = U.afilter(cite_attrs, function(p)
      return p[1] ~= "delimiter" and p[1] ~= "prefix" and p[1] ~= "suffix"
    end)
  else
    cite_attrs = U.aremove(cite_attrs, "delimiter")
  end
  local rendered
  if c.grouped then
    local opts = style.cite_opts
    local top = { kind = "top" }
    for _, x in ipairs(cites) do
      top[#top + 1] = x
    end
    local node = render_cite_or_group(
      top,
      style,
      links,
      layout_dl,
      aget(opts, "cite-group-delimiter"),
      aget(opts, "year-suffix-delimiter"),
      aget(opts, "after-collapse-delimiter")
    )
    rendered = rt.contents(node)
  elseif #cites > 1 then
    rendered = {}
    for i, it in ipairs(cites) do
      if i > 1 then
        rendered[#rendered + 1] = nf(layout_dl)
      end
      rendered[#rendered + 1] = cite_render(it, style, links) or false
    end
  else
    rendered = { cite_render(cites[1], style, links) or false }
  end
  rendered.n = #rendered
  local non_affixes = U.afilter(cite_attrs, function(p)
    return p[1] ~= "prefix" and p[1] ~= "suffix" and p[1] ~= "delimiter"
  end)
  local affixes = U.afilter(cite_attrs, function(p)
    return p[1] == "prefix" or p[1] == "suffix"
  end)
  local outer = #affixes > 0 and #non_affixes > 0 and non_affixes or nil
  local result = rt.cull_spaces_puncts(
    rt.finalize(rt.render_affixes(E.join_formatted(outer and affixes or cite_attrs, rendered, nil), true), piq)
  )
  if outer then
    result = { outer, nf(result) }
  end
  if c.mode == "textual" and not (style.category == "numeric" or style.category == "label") then
    local first = cites[1]
    local first_cite = first.kind == "group" and first[1] or first
    local author_cite = U.concat({
      { "suppress-author", nil },
      { "stop-rendering-at", "names" },
      { "prefix", nil },
      { "suffix", nil },
      { "locator", nil },
    }, first_cite)
    local ra = cite_render(author_cite, style, "no-links")
    if ra == nil or type(ra) == "table" then
      result = { {}, nf(ra), " ", nf(result) }
    end
  end
  if c.capitalize_first then
    result = rt.change_case(result, E.capitalize_first)
  end
  return result
end

--- citeproc-cites--collapse-indexed
local function collapse_indexed(cites, index_getter, no_span_pred)
  local group_len, start_cite, prev_index, end_cite
  local result = {}
  local function collapse_range(s, e, len)
    if len == 1 then
      return { s }
    elseif len == 2 then
      return { e, s }
    end
    return { { kind = "range", s, e } }
  end
  local function prepend(list)
    for i = #list, 1, -1 do
      table.insert(result, 1, list[i])
    end
  end
  for _, cite in ipairs(cites) do
    local cur = index_getter(cite)
    local no_span = no_span_pred(cite)
    local subsequent = prev_index ~= nil and prev_index + 1 == cur
    if group_len and (no_span or not subsequent) then
      prepend(collapse_range(start_cite, end_cite, group_len))
    end
    if no_span then
      table.insert(result, 1, cite)
      group_len = nil
    elseif not group_len or not subsequent then
      group_len = 1
      start_cite = cite
      prev_index = cur
    else
      group_len = group_len + 1
      end_cite = cite
      prev_index = cur
    end
  end
  if group_len then
    prepend(collapse_range(start_cite, end_cite, group_len))
  end
  if #cites ~= #result then
    local out = {}
    for i = #result, 1, -1 do
      out[#out + 1] = result[i]
    end
    return out
  end
  return nil
end

local function first_node_of(cite, proc, set)
  return rt.find_first_node(itd_rt_cite(aget(cite, "itd"), proc.style), function(x)
    return type(x) == "table" and set[aget(x[1], "rendered-var")] ~= nil
  end)
end

local function sort_cites(proc)
  local style = proc.style
  if not style.cite_sort then
    return
  end
  for _, c in ipairs(proc.citations) do
    if #c.cites > 1 then
      local keyed = {}
      for i, it in ipairs(c.cites) do
        table.insert(it, 1, { "key", E.render_keys(style, cite_varlist(it), "cite") })
        keyed[i] = it
      end
      c.cites = U.stable_sort(keyed, function(x, y)
        return E.compare_keylists(x[1][2], y[1][2], style.cite_sort_orders)
      end)
    end
  end
end

local function apply_citation_modes(proc)
  for _, c in ipairs(proc.citations) do
    local first = c.cites[1]
    if first then
      local rep = MODE_REP[c.mode]
      if rep then
        for _, p in ipairs(rep) do
          first[#first + 1] = { p[1], p[2] }
        end
      end
      if c.ignore_et_al then
        table.insert(first, 1, { "ignore-et-al", true })
      end
    end
  end
end

local function collapse_ys(cites, proc, ranges)
  local first = true
  local groups = { { cites[1] } }
  local prev_date, prev_loc
  for _, cite in ipairs(cites) do
    local varlist = cite_varlist(cite)
    local dnode = first_node_of(cite, proc, rt.DATE_VAR_SET)
    local date_cont = type(dnode) == "table" and dnode[2] or nil
    local locator = aget(varlist, "locator")
    if first then
      first = false
    elseif prev_loc or locator or not aget(varlist, "year-suffix") or not rt.equal(date_cont, prev_date) then
      table.insert(groups, 1, { U.concat({ { "suppress-author", true } }, cite) })
    else
      table.insert(groups[1], 1, U.concat({ { "suppress-date", true }, { "suppress-author", true } }, cite))
    end
    prev_date = date_cont
    prev_loc = locator
  end
  local out = {}
  for gi = #groups, 1, -1 do
    local it = groups[gi]
    if #it > 1 then
      local rev = {}
      for i = #it, 1, -1 do
        rev[#rev + 1] = it[i]
      end
      local items = rev
      if ranges and #cites > 2 then
        items = collapse_indexed(rev, function(x)
          local ys = aget(cite_varlist(x), "year-suffix") or " "
          return U.codepoints(ys)[1] or 0
        end, function()
          return false
        end) or rev
      end
      local g = { kind = "year-suffix-collapsed" }
      for _, x in ipairs(items) do
        g[#g + 1] = x
      end
      out[#out + 1] = g
    else
      out[#out + 1] = it[1]
    end
  end
  return out
end

local function group_and_collapse_cites(c, proc, collapse_type)
  local cites = c.cites
  if #cites < 2 then
    return
  end
  local groups = {}
  for _, cite in ipairs(cites) do
    local cont = first_node_of(cite, proc, rt.NAME_VAR_SET)
    local g_ind
    for gi, g in ipairs(groups) do
      local other = first_node_of(g[1], proc, rt.NAME_VAR_SET)
      if rt.equal(rt.contents(cont), rt.contents(other)) then
        g_ind = gi
        break
      end
    end
    if g_ind then
      table.insert(groups[g_ind], 1, cite)
    else
      table.insert(groups, 1, { cite })
    end
  end
  if #groups == #cites then
    return
  end
  local out = {}
  for gi = #groups, 1, -1 do
    local it = groups[gi]
    if #it > 1 then
      local rev = {}
      for i = #it, 1, -1 do
        rev[#rev + 1] = it[i]
      end
      local items
      if collapse_type == "year" then
        items = { rev[1] }
        for i = 2, #rev do
          items[#items + 1] = U.concat({ { "suppress-author", true } }, rev[i])
        end
      elseif collapse_type == "year-suffix" then
        items = collapse_ys(rev, proc, false)
      elseif collapse_type == "year-suffix-ranged" then
        items = collapse_ys(rev, proc, true)
      else
        items = rev
      end
      local g = { kind = "group" }
      for _, x in ipairs(items) do
        g[#g + 1] = x
      end
      out[#out + 1] = g
    else
      out[#out + 1] = it[1]
    end
  end
  c.cites = out
  c.grouped = true
end

local function group_and_collapse(proc)
  local opts = proc.style.cite_opts
  local group_delim = aget(opts, "cite-group-delimiter")
  local ctype = aget(opts, "collapse")
  local year_type = ctype == "year" or ctype == "year-suffix" or ctype == "year-suffix-ranged"
  if group_delim or year_type then
    for _, c in ipairs(proc.citations) do
      group_and_collapse_cites(c, proc, ctype)
    end
  elseif ctype == "citation-number" then
    for _, c in ipairs(proc.citations) do
      if #c.cites > 2 then
        local collapsed = collapse_indexed(c.cites, function(x)
          return U.to_number(aget(cite_varlist(x), "citation-number"))
        end, function(x)
          return aget(cite_varlist(x), "locator")
        end)
        if collapsed then
          c.cites = collapsed
          c.grouped = true
        end
      end
    end
  end
end

local function loc_equal_p(s1, s2)
  if E.numeric_p(s1) and E.numeric_p(s2) then
    return vim.deep_equal(E.number_extract(s1), E.number_extract(s2))
  end
  return U.trim(s1) == U.trim(s2)
end

--- citeproc-disambiguation-cite-pos: "last", "first" or "subsequent".
M.disambiguation_cite_pos = "last"

local function update_positions(proc)
  proc.itemdata:each(function(_, itd)
    itd.occurred_before = nil
  end)
  if M.disambiguation_cite_pos ~= "last" then
    proc.itemdata:each(function(_, itd)
      itd.disamb_pos = M.disambiguation_cite_pos
    end)
  end
  local nnd = U.to_number(aget(proc.style.cite_opts, "near-note-distance") or "5")
  local queue = {}
  local prev_itd, prev_loc, prev_label
  for _, ctn in ipairs(proc.citations) do
    local note = ctn.note_index
    local cites = ctn.cites
    local single = #cites < 2
    if note then
      while queue[1] and nnd < note - queue[1].note_index do
        table.remove(queue, 1)
      end
    end
    local seen = {}
    for _, cite in ipairs(cites) do
      local itd = aget(cite, "itd")
      local locator = aget(cite, "locator")
      local label = aget(cite, "label")
      local pos
      if itd.occurred_before then
        if itd == prev_itd then
          if prev_loc then
            if locator then
              if loc_equal_p(prev_loc, locator) and prev_label == label then
                pos = "ibid"
              else
                pos = "ibid-with-locator"
              end
            else
              pos = "subsequent"
            end
          else
            pos = locator and "ibid-with-locator" or "ibid"
          end
        else
          pos = "subsequent"
        end
      else
        pos = "first"
      end
      if note then
        local referred = seen[itd] ~= nil
        if not referred then
          for _, q in ipairs(queue) do
            for _, qc in ipairs(q.cites) do
              if aget(qc, "itd") == itd then
                referred = true
              end
            end
          end
        end
        if referred then
          aset_in_place(cite, "near-note", true)
        end
      end
      aset_in_place(cite, "position", pos)
      prev_itd, prev_loc, prev_label = itd, locator, label
      if M.disambiguation_cite_pos == "last" then
        itd_update_disamb_pos(itd, pos)
      end
      local prev = itd.occurred_before
      if prev then
        if prev ~= true then
          aset_in_place(cite, "first-reference-note-number", U.num_str(prev))
        end
      else
        itd.occurred_before = note or true
      end
      seen[itd] = true
    end
    if not single then
      prev_itd, prev_loc, prev_label = nil, nil, nil
    end
    if note then
      queue[#queue + 1] = ctn
    end
  end
end

--- citeproc-proc-finalize
function M.finalize(proc)
  if proc.finalized then
    return
  end
  process_uncited(proc)
  sb_add_subbib_info(proc)
  sb_prune_unrendered(proc)
  update_sortkeys(proc)
  proc_sort_itds(proc)
  update_positions(proc)
  proc_disamb(proc)
  sort_cites(proc)
  apply_citation_modes(proc)
  group_and_collapse(proc)
  proc.finalized = true
end

---------------------------------------------------------------------------
-- Public API (citeproc.el)
---------------------------------------------------------------------------

--- citeproc-create
function M.create(style_file, getter, locale_getter, locale, force_locale)
  return {
    style = S.create(style_file, locale_getter, locale, force_locale),
    getter = getter,
    names = {},
    names_count = 0,
    itemdata = U.ordered(),
    citations = {},
    uncited = {},
    finalized = true,
  }
end

--- A citation: { cites = { cite alists }, note_index, mode, suppress_affixes,
--- capitalize_first, ignore_et_al }.
function M.citation_create(t)
  return {
    cites = t.cites or {},
    note_index = t.note_index,
    mode = t.mode,
    suppress_affixes = t.suppress_affixes,
    capitalize_first = t.capitalize_first,
    ignore_et_al = t.ignore_et_al,
  }
end

--- citeproc-append-citations
function M.append_citations(citations, proc)
  local ids, seen = {}, {}
  for _, c in ipairs(citations) do
    for _, cite in ipairs(c.cites) do
      local id = aget(cite, "id")
      local key = id == nil and seen or id
      if not seen[key] then
        seen[key] = true
        ids[#ids + 1] = id
      end
    end
  end
  local new_ids = {}
  for _, id in ipairs(ids) do
    if proc.itemdata:get(id) == nil then
      new_ids[#new_ids + 1] = id
    end
  end
  put_items_by_id(proc, new_ids)
  for _, c in ipairs(citations) do
    local cites = {}
    for i, it in ipairs(c.cites) do
      local cite = internalize_locator(it)
      table.insert(cite, 1, { "itd", proc.itemdata:get(aget(cite, "id")) })
      cites[i] = cite
    end
    c.cites = cites
    proc.citations[#proc.citations + 1] = c
  end
  proc.finalized = false
end

--- citeproc-add-uncited
function M.add_uncited(itemids, proc)
  table.insert(proc.uncited, 1, itemids)
  proc.finalized = false
end

--- citeproc-add-subbib-filters
function M.add_subbib_filters(filters, proc)
  proc.bib_filters = filters
  proc.finalized = false
end

--- citeproc-render-citations
function M.render_citations(proc, format, internal_links)
  M.finalize(proc)
  local fmt = F.for_format(format)
  local out = {}
  for i, c in ipairs(proc.citations) do
    -- a nil citation is "" (s-join / concat treat nil as empty)
    out[i] = fmt.cite(fmt.rt(citation_render(c, proc, internal_links))) or ""
  end
  return out
end

local function max_offset(proc)
  local max
  proc.itemdata:each(function(_, itd)
    local r = itd.rawbibitem
    if r == nil or r == false or type(r) == "table" then
      local l = U.len(rt.to_plain(type(r) == "table" and r[2] or nil))
      if max == nil or l > max then
        max = l
      end
    end
  end)
  return max or 0
end

--- citeproc-render-bib: formatted bibliography (a list of them with
--- filters) and the formatting parameters.
function M.render_bib(proc, format, internal_links, no_external_links)
  local style = proc.style
  if not style.bib_layout then
    return "[NO BIBLIOGRAPHY LAYOUT IN CSL STYLE]"
  end
  M.finalize(proc)
  local fmt = F.for_format(format)
  local piq = aget(style.locale_opts, "punctuation-in-quote") == "true"
  local filters = proc.bib_filters
  proc.itemdata:each(function(_, itd)
    itd.rawbibitem = rt.finalize(
      E.render_varlist_in_rt(itd.varvals, style, "bib", "display", internal_links, fmt.no_external_links or no_external_links),
      piq
    )
  end)
  local raw_bib
  if filtered_bib_p(proc) then
    local n = #filters
    local result = {}
    for i = 1, n do
      result[i] = {}
    end
    local to_sort = {}
    proc.itemdata:each(function(_, itd)
      local nos = itd.subbib_nos or {}
      for k = 2, #nos do
        to_sort[nos[k] + 1] = true
      end
      for _, no in ipairs(nos) do
        table.insert(result[no + 1], 1, itd)
      end
    end)
    raw_bib = {}
    for i = 1, n do
      local list
      if style.bib_sort and to_sort[i] then
        list = sort_itds(result[i], style.bib_sort_orders)
      else
        list = sort_on_citnum(result[i])
      end
      local items = {}
      for k, itd in ipairs(list) do
        items[k] = nf(itd.rawbibitem)
      end
      raw_bib[i] = items
    end
  else
    local items = {}
    for k, itd in ipairs(sort_on_citnum(proc.itemdata:values())) do
      items[k] = nf(itd.rawbibitem)
    end
    raw_bib = { items }
  end
  local sub = aget(style.bib_opts, "subsequent-author-substitute")
  if sub then
    for i, b in ipairs(raw_bib) do
      raw_bib[i] = rt.subsequent_author_substitute(b, sub)
    end
  end
  local offset = 0
  if aget(style.bib_opts, "second-field-align") and proc.itemdata:count() > 0 then
    offset = max_offset(proc)
  end
  local params = acons("max-offset", offset, S.bib_opts_to_formatting_params(style.bib_opts))
  local formatted = {}
  for i, b in ipairs(raw_bib) do
    local items = {}
    for k, x in ipairs(b) do
      items[k] = fmt.bib_item(fmt.rt(rt.cull_spaces_puncts(x)), params) or ""
    end
    formatted[i] = fmt.bib(items, params)
  end
  return (filters and #filters > 0) and formatted or formatted[1], params
end

return M
