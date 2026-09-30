---@mod org.extensions.merge.diff3 Line-level three-way merge
---
--- A small diff3 on top of Neovim's xdiff (`vim.text.diff`, or `vim.diff`
--- before Neovim 0.11): the changes base -> ours and base -> theirs are
--- found, changes that overlap or touch are grouped, and a group changed on
--- one side (or the same way on both) is taken while one changed
--- differently on both sides becomes a conflict. Like git, changes to
--- adjacent lines conflict.

local M = {}

local xdiff = (vim.text and vim.text.diff) or vim.diff

local function join(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Changed ranges of `b` against `a`, in half-open base coordinates:
--- `{ s = first base line, e = one past the last, lines = new lines }`.
---@param a string[]
---@param b string[]
local function hunks(a, b)
  local out = {}
  local idx = xdiff(join(a), join(b), { result_type = "indices", algorithm = "histogram" })
  for _, h in ipairs(idx or {}) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    -- a pure insertion (ca == 0) comes after base line sa
    local s = ca == 0 and sa + 1 or sa
    local new = {}
    local first = cb == 0 and sb + 1 or sb
    for i = first, first + cb - 1 do
      new[#new + 1] = b[i]
    end
    out[#out + 1] = { s = s, e = s + ca, lines = new }
  end
  return out
end

--- The side's text for base lines [s, e) given its hunks inside that range.
local function side_text(base, s, e, hs)
  local out = {}
  local pos = s
  for _, h in ipairs(hs) do
    for i = pos, h.s - 1 do
      out[#out + 1] = base[i]
    end
    vim.list_extend(out, h.lines)
    pos = h.e
  end
  for i = pos, e - 1 do
    out[#out + 1] = base[i]
  end
  return out
end

local function same(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

---@class org.merge.Diff3Opts
---@field marker_size? integer length of the conflict markers (7)
---@field ours_label? string text after `<<<<<<<` ("ours")
---@field theirs_label? string text after `>>>>>>>` ("theirs")
---@field base_label? string with `style = "diff3"`, text after `|||||||` ("base")
---@field style? "merge"|"diff3" "diff3" also shows the base text

--- Conflict lines for two alternatives.
---@param ours string[]
---@param theirs string[]
---@param opts? org.merge.Diff3Opts
---@param base? string[]
---@return string[]
function M.markers(ours, theirs, opts, base)
  opts = opts or {}
  local n = opts.marker_size or 7
  local out = { string.rep("<", n) .. " " .. (opts.ours_label or "ours") }
  vim.list_extend(out, ours)
  if opts.style == "diff3" and base then
    out[#out + 1] = string.rep("|", n) .. " " .. (opts.base_label or "base")
    vim.list_extend(out, base)
  end
  out[#out + 1] = string.rep("=", n)
  vim.list_extend(out, theirs)
  out[#out + 1] = string.rep(">", n) .. " " .. (opts.theirs_label or "theirs")
  return out
end

--- Three-way merge of line lists.
---@param base string[]
---@param ours string[]
---@param theirs string[]
---@param opts? org.merge.Diff3Opts
---@return string[] lines merged lines, with conflict markers where needed
---@return integer conflicts number of conflict regions
function M.merge(base, ours, theirs, opts)
  if same(ours, theirs) then
    return vim.list_extend({}, ours), 0
  elseif same(base, ours) then
    return vim.list_extend({}, theirs), 0
  elseif same(base, theirs) then
    return vim.list_extend({}, ours), 0
  end
  local all = {}
  for _, h in ipairs(hunks(base, ours)) do
    h.side = 1
    all[#all + 1] = h
  end
  for _, h in ipairs(hunks(base, theirs)) do
    h.side = 2
    all[#all + 1] = h
  end
  table.sort(all, function(a, b)
    if a.s ~= b.s then
      return a.s < b.s
    end
    return a.side < b.side
  end)
  -- group hunks that overlap or touch
  local groups = {}
  for _, h in ipairs(all) do
    local g = groups[#groups]
    if g and h.s <= g.e then
      g.e = math.max(g.e, h.e)
      table.insert(g[h.side], h)
    else
      g = { s = h.s, e = h.e, {}, {} }
      table.insert(g[h.side], h)
      groups[#groups + 1] = g
    end
  end
  local out, conflicts = {}, 0
  local pos = 1
  for _, g in ipairs(groups) do
    for i = pos, g.s - 1 do
      out[#out + 1] = base[i]
    end
    local o = side_text(base, g.s, g.e, g[1])
    local t = side_text(base, g.s, g.e, g[2])
    if #g[1] == 0 then
      vim.list_extend(out, t)
    elseif #g[2] == 0 or same(o, t) then
      vim.list_extend(out, o)
    else
      local b = {}
      for i = g.s, g.e - 1 do
        b[#b + 1] = base[i]
      end
      vim.list_extend(out, M.markers(o, t, opts, b))
      conflicts = conflicts + 1
    end
    pos = g.e
  end
  for i = pos, #base do
    out[#out + 1] = base[i]
  end
  return out, conflicts
end

return M
