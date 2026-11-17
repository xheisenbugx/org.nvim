---@mod org.agenda.items.timestamps Timestamps and date ranges in the day agenda
---
--- The plain timestamp (org-agenda-get-timestamps), date range
--- (org-agenda-get-blocks) and `<%%(sexp)>` stamp lines of an entry, and
--- its inactive timestamps (org-agenda-include-inactive-timestamps).
--- Part of org.agenda.items, which loads it.

-- Not compiled by the JIT, like org.agenda.items (see the comment there).
if jit then
  jit.off(true, true)
end

local date = require("org.date")
local habits = require("org.agenda.habits")
local shared = require("org.agenda.items.shared")

local M = require("org.agenda.items")

local at_date_range = shared.at_date_range
local at_day = shared.at_day
local block_sources = shared.block_sources
local future_repeats = shared.future_repeats
local new_item = shared.new_item
local prefers_last = shared.prefers_last
local range_dotime = shared.range_dotime
local repeating = shared.repeating
local set_time = shared.set_time

local last_occ = M.last_occ

local sexp_mod

--- The plain timestamps and date ranges of `hl`, and its `<%%(sexp)>`
--- stamps when its file has sexps (`sexps`). A timestamp on a day in
--- `dl_shown` may be skipped (agenda.skip_timestamp_if_deadline_is_shown);
--- `before_first` (an inline task before the first heading) gets its
--- date ranges only.
---@param ctx org.agenda.items.DayContext
---@param hl org.Headline
---@param done boolean
---@param sexps boolean
---@param dl_shown table<integer, boolean>
---@param before_first boolean
function shared.timestamps(ctx, hl, done, sexps, dl_shown, before_first)
  local acfg, block_acfg, types, today, from, to, add =
    ctx.acfg, ctx.block_acfg, ctx.types, ctx.today, ctx.from, ctx.to, ctx.add
  local leaders_r, eval_sexp = ctx.leaders_r, ctx.eval_sexp
  if types.timestamp then
    local seen_day = {}
    for _, t in ipairs(block_sources(hl)) do
      local ts = t.date
      if done and acfg.skip_timestamp_if_done then
        break
      end
      if ts.range_end and types.timestamp then
        -- org-agenda-get-blocks
        local a, b = ts:days(), ts.range_end:days()
        local n = b - a + 1
        for d = math.max(a, from), math.min(b, to) do
          local item = new_item(hl, {
            type = "range",
            ts_type = "block",
            date = ts,
            ts_index = not t.planning and t.index or nil,
            planning_kind = t.planning,
            block_range = (not t.planning and not t.index) or nil,
            extra = string.format(a == b and leaders_r[1] or leaders_r[2], d - a + 1, n),
            face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
            undone_face = "OrgAgendaTimestamp",
            fixface = true,
          })
          if acfg.remove_timeranges_from_blocks and t.line == hl.line and t.start_col then
            -- org-agenda-remove-timeranges-from-blocks: drop the range
            -- from the headline text
            local text = (hl.file.lines[t.line] or ""):sub(t.start_col, t.end_col)
            local s, e = item.title:find(text, 1, true)
            if s then
              item.title = item.title:sub(1, s - 1) .. item.title:sub(e + 1)
            end
          end
          -- the time comes from the range as written, as Emacs reads it:
          -- "<a>--<b 13:15>" is at 13:15, "<a 06:00> x>--<a 09:45>" at
          -- 6:00 without an end
          local which = (d == a and d == b) and "both" or (d == a and "start") or (d == b and "end") or nil
          local raw = which and t.start_col and t.end_col and hl.file.lines[t.line]
          local dotime = raw and range_dotime(raw:sub(t.raw_col or t.start_col, t.end_col), which)
          if dotime then
            set_time(item, nil, block_acfg, nil, nil, dotime)
          elseif which == "both" then
            set_time(
              item,
              ts.hour and ts:clone({ end_hour = ts.range_end.hour, end_min = ts.range_end.min }) or ts,
              block_acfg
            )
          elseif which == "start" then
            set_time(item, ts, block_acfg)
          elseif which == "end" then
            set_time(item, ts.range_end, block_acfg)
          end
          add(d, item)
        end
      elseif
        not ts.range_end
        and types.timestamp
        and not before_first
        and not (t.start_col and at_date_range(hl.file.lines[t.line] or "", t.start_col))
      then
        -- org-agenda-get-timestamps
        local show_days = {}
        -- its regexp repeats a stamp only when the repeater ends it
        -- ("<a +1w>", not "<a +1w -4d>" nor "<a .+1w/2w>"); another one
        -- shows on its date only
        local raw = t.start_col and (hl.file.lines[t.line] or ""):sub(t.start_col, t.end_col)
        if repeating(ts) and (not raw or raw:find("^<%d+%-%d+%-%d+[^>\n]+%+%d+[hdwmy]>$")) then
          local last = prefers_last(acfg, hl.todo)
          local seen = {}
          for d = from, math.min(to, today) do
            local past = last_occ(ts, last and today or d)
            if past == d then
              show_days[#show_days + 1] = d
              seen[d] = true
            end
          end
          -- after today: the last repeat before today (the base when it is
          -- in the future) and the future repeats
          local p = last_occ(ts, today)
          if p > today and p >= from and p <= to then
            show_days[#show_days + 1] = p
            seen[p] = true
          end
          for _, d in ipairs(future_repeats(ts, acfg, today, from, to)) do
            if not seen[d] then
              show_days[#show_days + 1] = d
            end
          end
        elseif ts:days() >= from and ts:days() <= to then
          show_days[1] = ts:days()
        end
        for _, d in ipairs(show_days) do
          local skip = (acfg.skip_timestamp_if_deadline_is_shown and dl_shown[d])
            or (acfg.skip_additional_timestamps_same_entry and seen_day[d])
          if not skip then
            seen_day[d] = true
            local item = new_item(hl, {
              type = "timestamp",
              ts_type = "timestamp",
              date = at_day(ts, d),
              ts_date = ts:days(),
              ts_index = t.index,
              extra = "",
              face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
              undone_face = "OrgAgendaTimestamp",
              fixface = true,
            })
            if habits.is_habit(hl) then
              local h = habits.parse(hl)
              if h then
                item.urgency = habits.urgency(h, today)
              end
            end
            set_time(item, ts, acfg, true)
            add(d, item)
          end
        end
      end
    end
    -- <%%(sexp)> timestamps
    if types.timestamp and sexps and not before_first then
      local lines = hl.file.lines
      for i = hl.line, hl.body_end do
        local line = lines[i] or ""
        if line:find("<%%(", 1, true) and i ~= hl.planning_line then
          sexp_mod = sexp_mod or require("org.agenda.sexp")
          for _, m in ipairs(sexp_mod.find_all(line)) do
            for d = from, to do
              if eval_sexp(m.sexp, d, "") then
                local item = new_item(hl, {
                  type = "timestamp",
                  ts_type = "timestamp",
                  extra = "",
                  sexp = m.sexp,
                  face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
                  undone_face = "OrgAgendaTimestamp",
                  fixface = true,
                })
                -- the whole stamp is DOTIME: a time after the sexp
                -- ("<%%(diary-float t 4 2) 22:00-23:00>") is the entry's
                set_time(item, nil, acfg, true, m.sexp .. m.text_after)
                add(d, item)
              end
            end
          end
        end
      end
    end
  end
end

--- The inactive timestamps and date ranges of `hl`
--- (org-agenda-include-inactive-timestamps), with `opts.inactive`.
---@param ctx org.agenda.items.DayContext
---@param hl org.Headline
---@param done boolean
---@param before_first boolean
function shared.inactive_timestamps(ctx, hl, done, before_first)
  local acfg, block_acfg, types, from, to, add, opts =
    ctx.acfg, ctx.block_acfg, ctx.types, ctx.from, ctx.to, ctx.add, ctx.opts
  local leaders_r, inactive_leader = ctx.leaders_r, ctx.inactive_leader
  if opts.inactive and types.timestamp and not before_first then
    local lines = hl.file.lines
    local pr = hl.properties_range
    for i = hl.line, hl.body_end do
      local line = lines[i] or ""
      local skip = i == hl.planning_line or (pr and i >= pr[1] and i <= pr[2]) or line:match("^%s*CLOCK:")
      if not skip then
        for _, m in ipairs(date.parse_all(line)) do
          local ts = m.date
          local last = ts.range_end and ts.range_end:days() or ts:days()
          if not ts.active and last >= from and ts:days() <= to then
            if not (done and acfg.skip_timestamp_if_done) then
              if ts.range_end then
                local a, b = ts:days(), ts.range_end:days()
                for d = math.max(a, from), math.min(b, to) do
                  local item = new_item(hl, {
                    type = "range",
                    ts_type = "block",
                    date = ts,
                    extra = inactive_leader
                      .. string.format(a == b and leaders_r[1] or leaders_r[2], d - a + 1, b - a + 1),
                    face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
                    undone_face = "OrgAgendaTimestamp",
                    fixface = true,
                    inactive = true,
                  })
                  local which = (d == a and d == b) and "both" or (d == a and "start") or (d == b and "end") or nil
                  local dotime = which and range_dotime(m.raw, which)
                  if dotime then
                    set_time(item, nil, block_acfg, nil, nil, dotime)
                  else
                    set_time(item, d == a and ts or (d == b and ts.range_end) or nil, block_acfg)
                  end
                  add(d, item)
                end
              else
                local item = new_item(hl, {
                  type = "timestamp",
                  ts_type = "timestamp",
                  date = ts,
                  ts_date = ts:days(),
                  extra = inactive_leader,
                  face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
                  undone_face = "OrgAgendaTimestamp",
                  fixface = true,
                  inactive = true,
                })
                set_time(item, ts, acfg, true)
                add(ts:days(), item)
              end
            end
          end
        end
      end
    end
  end
end
