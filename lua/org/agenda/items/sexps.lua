---@mod org.agenda.items.sexps Diary sexps in the day agenda
---
--- Evaluating `%%(sexp)` lines and `<%%(sexp)>` stamps for the days of a
--- day agenda (org.agenda.sexp, else Emacs), the `%%(sexp)` entries
--- (org-agenda-get-sexps) and SCHEDULED/DEADLINE sexp dates. Part of
--- org.agenda.items, which loads it.

-- Not compiled by the JIT, like org.agenda.items (see the comment there).
if jit then
  jit.off(true, true)
end

local shared = require("org.agenda.items.shared")

local M = require("org.agenda.items")

local file_item = shared.file_item
local new_item = shared.new_item
local set_time = shared.set_time

local sexp_mod

--- The sexp evaluator of a day agenda over days [from, to]:
--- `fun(sexp, day, text)` returning the sexp's value on `day`. Sexps are
--- parsed once; a bad one is reported once per session and skipped, like
--- Emacs's "Bad sexp ... Skipping".
---@param from integer
---@param to integer
---@return fun(s: string, day: integer, text?: string): any
function shared.sexp_evaluator(from, to)
  local parsed, warned = {}, M._warned_sexps
  local function warn_once(s, err)
    if not warned[s] then
      warned[s] = true
      vim.schedule(function()
        vim.notify(string.format("org agenda: bad sexp %s: %s; skipping", s, tostring(err)), vim.log.levels.WARN)
      end)
    end
  end
  -- beyond the emulation: evaluate the sexp for the whole range in Emacs
  local function eval_in_emacs(s, day, text, err)
    local key = table.concat({ s, text or "", from, to }, "\0")
    local by_day = M._emacs_sexps[key]
    if by_day == nil and require("org.babel.elisp").command() then
      by_day = sexp_mod.eval_emacs(s, from, to, text or "") or false
      M._emacs_sexps[key] = by_day
    end
    if by_day and by_day[day] ~= nil then
      return by_day[day]
    end
    warn_once(s, err)
    return nil
  end
  local function eval_sexp(s, day, text)
    sexp_mod = sexp_mod or require("org.agenda.sexp")
    local node = parsed[s]
    local err
    if node == nil then
      node, err = sexp_mod.parse(s)
      node = node or false
      parsed[s] = node
    end
    if not node then
      return eval_in_emacs(s, day, text, err or "invalid sexp")
    end
    local ok, res
    ok, res, err = pcall(sexp_mod.eval, node, day, text or "")
    if not ok or (res == nil and err) then
      return eval_in_emacs(s, day, text, ok and err or res)
    end
    return res
  end
  return eval_sexp
end

--- %%(sexp) lines first..last of `file` (org-agenda-get-sexps). `hl` is
--- nil before the first heading: the items then have the file's category.
--- Like org-agenda-skip, lines inside src blocks are left out.
---@param ctx org.agenda.items.DayContext
---@param hl org.Headline|nil
---@param file org.File
---@param first integer
---@param last integer
function shared.add_sexps(ctx, hl, file, first, last)
  local acfg, from, to, add, eval_sexp = ctx.acfg, ctx.from, ctx.to, ctx.add, ctx.eval_sexp
  local lines = file.lines
  local block_end, in_src = 0, false
  for i = first, last do
    local line = lines[i] or ""
    if i > block_end and line:find("^%s*#%+") then
      local e, name = require("org.parser").verbatim_block_end(lines, i, last)
      if e then
        block_end, in_src = e, name == "src"
      end
    end
    if not (in_src and i <= block_end) and line:match("^&?%%%%%(") then
      sexp_mod = sexp_mod or require("org.agenda.sexp")
      local e = sexp_mod.line_entry(line)
      if e then
        for d = from, to do
          local res = eval_sexp(e.sexp, d, e.text)
          -- a string result is split on "; " into several entries
          local texts = type(res) == "string" and vim.split(res, "; ", { plain = true }) or (res and { e.text })
          for _, text in ipairs(texts or {}) do
            local extra = ""
            local prefix = acfg.diary_sexp_prefix
            if type(prefix) == "string" and prefix ~= "" then
              -- org-agenda-diary-sexp-prefix: the match becomes the leader
              local ok_re, pat = pcall(require("org.agenda.search").emacs_regexp, prefix)
              local m = ok_re and vim.fn.matchstrpos(text, "\\C" .. pat) or { "", -1, -1 }
              if m[2] >= 0 then
                extra = m[1]
                text = text:sub(1, m[2]) .. text:sub(m[3] + 1)
              end
            end
            if not text:match("%S") then
              text = "SEXP entry returned empty string"
            end
            local fields = {
              type = "sexp",
              ts_type = "sexp",
              title = text,
              extra = extra,
              sexp = e.sexp,
              lnum_sexp = i,
              face = "OrgAgendaTimestamp",
            }
            local item = hl and new_item(hl, fields) or file_item(file, i, fields)
            item.todo, item.priority, item.done = nil, nil, false
            -- org-agenda-get-sexps gives no priority or urgency (0 when
            -- sorting), whatever the entry's priority cookie
            item.prio, item.urgency = 0, 0
            set_time(item, nil, acfg)
            add(d, item)
          end
        end
      end
    end
  end
end

--- The sexp entries of `hl` (in a file with sexps): its %%(sexp) lines
--- (org-agenda-get-sexps) and its sexp planning dates
--- (SCHEDULED/DEADLINE: <%%(...)>).
---@param ctx org.agenda.items.DayContext
---@param hl org.Headline
---@param done boolean
function shared.sexp_entries(ctx, hl, done)
  local acfg, types, from, to, add, eval_sexp = ctx.acfg, ctx.types, ctx.from, ctx.to, ctx.add, ctx.eval_sexp
  -- %%(sexp) entries (org-agenda-get-sexps) ---------------------------
  if types.sexp then
    shared.add_sexps(ctx, hl, hl.file, hl.line + 1, hl.body_end)
  end
  -- sexp planning dates: SCHEDULED/DEADLINE: <%%(...)>
  for _, kind in ipairs({ "scheduled", "deadline" }) do
    local raw = hl.file.lines[hl.planning_line or (hl.line + 1)]
    local sx = raw and raw:match("^%s*%u+:") and raw:match(kind:upper() .. ":%s*<%%%%(%b())")
    if sx and types[kind] then
      for d = from, to do
        if
          eval_sexp(sx, d, "")
          and not (
            done
            and (
              kind == "deadline" and acfg.skip_deadline_if_done
              or kind == "scheduled" and acfg.skip_scheduled_if_done
            )
          )
        then
          local item = new_item(hl, {
            type = kind,
            ts_type = kind,
            extra = kind == "deadline" and ctx.leaders_d[1] or ctx.leaders_s[1],
            sexp = sx,
            face = kind == "deadline" and "OrgAgendaDeadline" or "OrgAgendaScheduled",
          })
          item.urgency = kind == "scheduled" and (99 + item.prio) or item.prio
          set_time(item, nil, acfg, false, sx)
          add(d, item)
        end
      end
    end
  end
end
