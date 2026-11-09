---@mod org.extensions.caldav.sync Two-way sync of a CalDAV calendar and org files
---
--- A sync of one calendar has three steps:
---
---  1. the server is asked what it has (hrefs and etags), and what changed
---     since the last sync is fetched;
---  2. the org files are read and compared, a field at a time, with the
---     calendar and with what both had at the last sync (the state file);
---     changes of the calendar are written into the entries, and what the
---     server must get is collected. This step never waits for the
---     network, so the buffers can't change under it;
---  3. the collected changes are sent.
---
--- An entry and a calendar component belong together when the entry's ID
--- property is the component's UID, as with Emacs's org-caldav.

local http = require("org.extensions.caldav.http")
local ical = require("org.extensions.caldav.ical")
local entry = require("org.extensions.caldav.entry")
local date = require("org.date")
local files = require("org.files")

local M = {}

local function ext()
  return require("org.extensions.caldav")
end

local function utils()
  return require("org.utils")
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

---@class org.caldav.Item
---@field href string
---@field etag string
---@field ics string the resource as the server had it
---@field type "VEVENT"|"VTODO"
---@field base table<string, string> the entry's fields at the last sync
---@field ro? boolean some of its fields are only changed in the calendar

---@class org.caldav.State
---@field version integer
---@field url string
---@field items table<string, org.caldav.Item> by UID
---@field skipped table<string, string> href -> etag of resources that aren't synced
---@field synced? integer when the last sync finished
---@field sig? string the options `skipped` was made with

--- The state file of a calendar.
---@param c org.caldav.Calendar
---@return string
function M.state_file(c)
  local dir = utils().expand(ext().opts().state_dir, vim.fn.getcwd())
  local name = c.name:gsub("[^%w_-]+", "_")
  return string.format("%s/%s-%s.json", dir, name, utils().sha256(http.collection(c.url)):sub(1, 12))
end

---@param c org.caldav.Calendar
---@return org.caldav.State
function M.load_state(c)
  local st = utils().read_json(M.state_file(c))
  if type(st) ~= "table" or st.version ~= 1 or type(st.items) ~= "table" then
    st = { version = 1 }
  end
  st.url = http.collection(c.url)
  -- (an empty table is stored as a list)
  st.items = type(st.items) == "table" and st.items or {}
  st.skipped = type(st.skipped) == "table" and st.skipped or {}
  -- an item that isn't whole is forgotten: its entry and its event are
  -- matched by ID again
  for uid, it in pairs(st.items) do
    local whole = type(it) == "table"
      and type(it.href) == "string"
      and type(it.ics) == "string"
      and type(it.base) == "table"
      and ical.FIELDS[it.type] ~= nil
    if not whole then
      st.items[uid] = nil
    else
      it.etag = type(it.etag) == "string" and it.etag or ""
    end
  end
  return st
end

---@param c org.caldav.Calendar
---@param st org.caldav.State
function M.save_state(c, st)
  -- vim.json writes an empty table as a list; keep the maps objects
  local data = vim.deepcopy(st)
  if next(data.items) == nil then
    data.items = vim.empty_dict()
  end
  if next(data.skipped) == nil then
    data.skipped = vim.empty_dict()
  end
  utils().write_json(M.state_file(c), data)
end

---------------------------------------------------------------------------
-- One calendar
---------------------------------------------------------------------------

---@class org.caldav.Result
---@field name string
---@field pulled integer entries added or changed from the calendar
---@field pushed integer events and tasks added or changed in the calendar
---@field deleted_local integer
---@field deleted_remote integer
---@field conflicts integer
---@field errors string[]
---@field notes string[]
---@field failed? string why the sync of the calendar stopped

---@class org.caldav.SyncContext: org.caldav.Context
---@field today integer
---@field past? integer days before today the sync goes back

---@class org.caldav.Push
---@field uid string
---@field href string
---@field etag? string nil: a new resource
---@field ics string
---@field type "VEVENT"|"VTODO"
---@field base table<string, string>
---@field title string
---@field ro? boolean

---@class org.caldav.Fetched
---@field href string
---@field etag string
---@field ics string
---@field type "VEVENT"|"VTODO"
---@field fields table<string, string>
---@field ro table<string, boolean>

---@param c org.caldav.Calendar
---@return org.caldav.SyncContext
function M.context(c)
  local o = ext().opts()
  local today = date.today_days()
  local past = ext().opt(c, "past_days")
  past = type(past) == "number" and past or nil
  return {
    timezone = o.timezone,
    tz_aliases = o.tz_aliases,
    zone_name = ext().zone_name(),
    from = today - (past or 30),
    to = today + (tonumber(o.recurrence_days) or 90),
    now = os.time(),
    today = today,
    past = past,
  }
end

---@param fields table<string, string>
---@param kind string
---@return table<string, string>
local function base_of(fields, kind)
  local b = {}
  for _, f in ipairs(ical.FIELDS[kind]) do
    b[f] = fields[f] or ""
  end
  return b
end

---@param fields table<string, string>
---@return string
local function title_of(fields)
  return (fields.summary or "") ~= "" and fields.summary or "(no title)"
end

--- Whether an event or task is recent enough to start syncing: one that
--- ended (or was closed) more than `past_days` ago is left alone.
---@param fields table<string, string>
---@param kind string
---@param ctx org.caldav.SyncContext
---@return boolean
local function recent(fields, kind, ctx)
  if not ctx.past then
    return true
  end
  local limit = ctx.today - ctx.past
  if kind == "VTODO" then
    if fields.status == "todo" then
      return true
    end
    local closed = fields._closed or fields._completed
    local d = closed and ical.key_date(closed)
    return not d or d:days() >= limit
  end
  for _, key in ipairs(vim.split(fields.time or "", "\n", { plain = true, trimempty = true })) do
    local d = ical.key_date(key)
    if d and (d.repeater or (d.range_end or d):days() >= limit) then
      return true
    end
  end
  return false
end

---@class org.caldav.Plan
---@field pushes org.caldav.Push[]
---@field deletes { uid: string, href: string, etag: string, title: string }[]

--- Step 2: compare the org files with the calendar, write the calendar's
--- changes into them and collect what the calendar must get.
---@param c org.caldav.Calendar
---@param st org.caldav.State
---@param all table<string, string> the resources the server has: href -> etag
---@param remote table<string, org.caldav.Fetched> new and changed resources by UID
---@param ctx org.caldav.SyncContext
---@param res org.caldav.Result
---@param run { interactive: boolean }
---@param paths string[]
---@return org.caldav.Plan|nil plan, string|nil err
local function reconcile(c, st, all, remote, ctx, res, run, paths)
  local e = ext()
  local dir = e.opt(c, "direction")
  local todos = e.opt(c, "todos") == true
  local winner = dir == "pull" and "remote" or dir == "push" and "local" or e.opt(c, "conflict")
  local inbox = e.inbox_of(c)

  local bufs = {}
  for i, path in ipairs(paths) do
    local ok, b = pcall(utils().load_buffer, path)
    if not ok then
      return nil, string.format("can't open %s: %s", path, tostring(b))
    end
    bufs[i] = b
  end
  local inbox_buf = inbox and bufs[1] or nil

  ---@type table<string, integer> UID -> the buffer its entry is in
  local where = {}
  local touched = {}
  local dup = {}
  ---@type { bufnr: integer, line: integer, uid: string|nil, kind: "VEVENT"|"VTODO" }[]
  local candidates = {}
  for _, b in ipairs(bufs) do
    local file = files.get_buffer(b)
    for _, hl in ipairs(file.headlines) do
      local uid = hl.properties.ID and vim.trim(hl.properties.ID) or ""
      if uid ~= "" then
        if where[uid] then
          if not dup[uid] then
            dup[uid] = true
            res.notes[#res.notes + 1] =
              string.format('two entries have the ID %s; only the first is synced ("%s")', uid, hl.title)
          end
        else
          where[uid] = b
        end
      end
      local known = uid ~= "" and (st.items[uid] or remote[uid] or dup[uid])
      if not known and dir ~= "pull" and not entry.excluded(hl) then
        local kind = entry.kind(file, hl, todos)
        if kind and recent((entry.read(file, hl, kind)), kind, ctx) then
          candidates[#candidates + 1] = { bufnr = b, line = hl.line, uid = uid ~= "" and uid or nil, kind = kind }
        end
      end
    end
  end
  -- new entries get an ID, from the last line up so the lines above stay put
  table.sort(candidates, function(a, b)
    if a.bufnr ~= b.bufnr then
      return a.bufnr < b.bufnr
    end
    return a.line > b.line
  end)
  for _, cand in ipairs(candidates) do
    if not cand.uid then
      cand.uid = require("org.id").get_create({ bufnr = cand.bufnr, lnum = cand.line })
      touched[cand.bufnr] = true
    end
    if cand.uid then
      where[cand.uid] = where[cand.uid] or cand.bufnr
    end
  end

  ---@type org.caldav.Plan
  local plan = { pushes = {}, deletes = {} }
  ---@type { uid: string, title: string }[]
  local del_local = {}
  ---@type { uid: string, title: string, href: string, etag: string }[]
  local del_remote = {}
  ---@type { uid: string, src: org.caldav.Fetched }[]
  local inserts = {}
  local count = vim.tbl_count(st.items)

  ---@param uid string
  ---@param kind "VEVENT"|"VTODO"
  ---@return table<string, string>|nil
  local function local_fields(uid, kind)
    local file, hl = entry.find(where[uid], uid)
    if not hl then
      return nil
    end
    return (entry.read(file, hl, kind))
  end

  ---@param uid string
  ---@param kind "VEVENT"|"VTODO"
  ---@param lf table<string, string>
  local function queue_new(uid, kind, lf)
    if kind == "VEVENT" and (lf.time or "") == "" then
      res.notes[#res.notes + 1] = string.format('"%s" has no timestamp: not sent', title_of(lf))
      return
    end
    local ics, err = ical.build(kind, uid, lf, ctx)
    if not ics then
      res.errors[#res.errors + 1] = string.format('"%s": %s', title_of(lf), err or "can't write it")
      return
    end
    plan.pushes[#plan.pushes + 1] = {
      uid = uid,
      href = http.href_for(c.url, uid),
      ics = ics,
      type = kind,
      base = base_of(lf, kind),
      title = title_of(lf),
    }
  end

  --- An entry and a component that belong together: settle each field.
  ---@param uid string
  ---@param S org.caldav.Item|nil what both had at the last sync
  ---@param R org.caldav.Fetched|nil the component, when it changed since
  local function merge(uid, S, R)
    local kind = (S and S.type or R and R.type) --[[@as "VEVENT"|"VTODO"]]
    local lf = local_fields(uid, kind)
    if not lf then
      return
    end
    if S and R and R.type ~= S.type then
      res.notes[#res.notes + 1] = string.format(
        '"%s" is now a %s in the calendar: not synced',
        title_of(lf),
        R.type == "VTODO" and "task" or "event"
      )
      return
    end
    -- what the calendar had at the last sync, read as of today (the
    -- occurrences listed for a rule move with the days)
    local old = S and (R or S.ro) and ical.read(S.ics, ctx) or nil
    local rf = R and R.fields or (old and old.fields) or nil
    local ro = R and R.ro or (old and old.ro) or {}
    local was = old and old.fields or (S and S.base) or {}
    local pull, push = {}, {}
    for _, f in ipairs(ical.FIELDS[kind]) do
      local l = lf[f] or ""
      local r = rf and (rf[f] or "") or nil
      local take
      if ro[f] then
        if r and l ~= r then
          take = "pull"
          if S and l ~= (S.base[f] or "") and dir ~= "push" then
            res.notes[#res.notes + 1] =
              string.format('"%s": its dates follow a rule of the calendar; change them there', title_of(lf))
          end
        end
      elseif not S then
        -- matched by ID for the first time: nothing says who changed what
        if r and l ~= r then
          if l == "" then
            take = "pull"
          elseif r == "" then
            take = "push"
          else
            take = winner == "local" and "push" or "pull"
          end
        end
      else
        local lc = l ~= (S.base[f] or "")
        local rc = R ~= nil and r ~= (was[f] or "")
        if lc and rc then
          if l ~= r then
            res.conflicts = res.conflicts + 1
            take = winner == "local" and "push" or "pull"
            res.notes[#res.notes + 1] = string.format(
              '"%s": %s changed here and in the calendar; kept %s',
              title_of(lf),
              f,
              take == "push" and "the org one" or "the calendar's"
            )
          end
        elseif lc then
          take = "push"
        elseif rc then
          take = "pull"
        end
      end
      if take == "pull" and dir ~= "push" then
        pull[f] = true
      elseif take == "push" and dir ~= "pull" then
        push[f] = true
      end
    end
    if push.time and (lf.time or "") == "" then
      push.time = nil
      res.notes[#res.notes + 1] = string.format('"%s" has no timestamp: its time is not sent', title_of(lf))
    end
    if rf and next(pull) then
      entry.apply(where[uid], uid, kind, rf, pull)
      touched[where[uid]] = true
      local now = local_fields(uid, kind) or lf
      -- (a value org can't hold as the calendar spells it reads back the same)
      if not vim.deep_equal(now, lf) then
        res.pulled = res.pulled + 1
      end
      lf = now
    end
    local cur = (R or S) --[[@as org.caldav.Item]]
    ---@type org.caldav.Item
    local item = {
      href = cur.href,
      etag = cur.etag,
      ics = cur.ics,
      type = kind,
      base = base_of(lf, kind),
      ro = next(ro) ~= nil or nil,
    }
    if next(push) then
      local ics, err = ical.patch(cur.ics, kind, lf, push, ctx)
      if not ics then
        res.errors[#res.errors + 1] = string.format('"%s": %s', title_of(lf), err or "can't write it")
      else
        plan.pushes[#plan.pushes + 1] = {
          uid = uid,
          href = cur.href,
          etag = cur.etag,
          ics = ics,
          type = kind,
          base = base_of(lf, kind),
          title = title_of(lf),
          ro = item.ro,
        }
      end
      -- until the server has them, the state keeps the calendar's values
      -- of those fields, so a change that isn't stored is sent again
      for f in pairs(push) do
        item.base[f] = rf and rf[f] or (S and S.base[f]) or ""
      end
    end
    st.items[uid] = item
  end

  local seen = {}
  local uids = vim.tbl_keys(st.items)
  table.sort(uids)
  for _, uid in ipairs(uids) do
    local S = st.items[uid]
    local R = remote[uid]
    seen[uid] = true
    if R then
      S.href = R.href
    end
    local gone = not R and all[S.href] == nil
    local here = where[uid] ~= nil
    if here and not gone then
      merge(uid, S, R)
    elseif here then
      -- deleted in the calendar
      local lf = local_fields(uid, S.type) or {}
      local changed = false
      for _, f in ipairs(ical.FIELDS[S.type]) do
        changed = changed or (lf[f] or "") ~= (S.base[f] or "")
      end
      if dir == "push" or (dir == "twoway" and changed and not S.ro) then
        queue_new(uid, S.type, lf)
      else
        del_local[#del_local + 1] = { uid = uid, title = title_of(lf) }
      end
    elseif not gone then
      -- deleted in the org files
      if dir == "pull" or (dir == "twoway" and R) then
        ---@type org.caldav.Fetched|nil
        local src = R
        if not src then
          local old = ical.read(S.ics, ctx)
          src = old and { href = S.href, etag = S.etag, ics = S.ics, type = old.type, fields = old.fields, ro = old.ro }
        end
        if src then
          inserts[#inserts + 1] = { uid = uid, src = src }
        end
      else
        del_remote[#del_remote + 1] = { uid = uid, title = title_of(S.base), href = S.href, etag = S.etag }
      end
    else
      st.items[uid] = nil
    end
  end

  local ruids = vim.tbl_keys(remote)
  table.sort(ruids)
  for _, uid in ipairs(ruids) do
    if not seen[uid] then
      seen[uid] = true
      local R = remote[uid]
      if where[uid] then
        merge(uid, nil, R)
      elseif dir == "push" or not recent(R.fields, R.type, ctx) then
        st.skipped[R.href] = R.etag
      else
        inserts[#inserts + 1] = { uid = uid, src = R }
      end
    end
  end

  for _, cand in ipairs(candidates) do
    local uid = cand.uid
    if uid and not seen[uid] then
      seen[uid] = true
      local lf = local_fields(uid, cand.kind)
      if lf then
        queue_new(uid, cand.kind, lf)
      end
    end
  end

  --- Whether to delete what `list` names: the option decides, "ask" asks
  --- once for all of them. nil: not now (nobody to ask).
  ---@param list { title: string }[]
  ---@param policy string
  ---@param question string
  ---@return boolean|nil
  local function decide(list, policy, question)
    if #list == 0 then
      return false
    end
    -- everything at once looks like a lost file or another calendar
    if policy == "always" and count >= 2 and #list >= count then
      policy = "ask"
    end
    if policy == "always" then
      return true
    elseif policy == "never" then
      return false
    end
    if not run.interactive or utils().is_noninteractive() then
      res.notes[#res.notes + 1] = string.format("%d deletion(s) wait for :Org caldav_sync to ask about them", #list)
      return nil
    end
    local lines = { "caldav: " .. c.name, question }
    for i, d in ipairs(list) do
      if i > 10 then
        lines[#lines + 1] = string.format("  ... and %d more", #list - 10)
        break
      end
      lines[#lines + 1] = "  " .. d.title
    end
    local answer = utils().confirm(table.concat(lines, "\n"))
    -- the question leaves the message area, or the sync's own message
    -- below it would need a Press ENTER
    pcall(vim.cmd --[[@as fun(command: string)]], "redraw")
    return answer
  end

  local yes = decide(
    del_local,
    e.opt(c, "delete_local"),
    #del_local == 1 and "1 entry was deleted in the calendar. Delete it from the org files too?"
      or string.format("%d entries were deleted in the calendar. Delete them from the org files too?", #del_local)
  )
  for _, d in ipairs(del_local) do
    if yes then
      local ok, why = entry.delete(where[d.uid], d.uid)
      -- an entry that is kept stays as it is, as with org-caldav: asked
      -- about again the next time, and sent again once it changes
      if ok then
        touched[where[d.uid]] = true
        res.deleted_local = res.deleted_local + 1
        st.items[d.uid] = nil
      else
        res.notes[#res.notes + 1] = string.format('"%s" is kept: %s', d.title, why or "")
      end
    end
  end

  if
    decide(
      del_remote,
      e.opt(c, "delete_remote"),
      #del_remote == 1 and "1 entry was deleted in the org files. Delete it from the calendar too?"
        or string.format("%d entries were deleted in the org files. Delete them from the calendar too?", #del_remote)
    )
  then
    plan.deletes = del_remote
  end

  if #inserts > 0 then
    if not inbox_buf or not inbox then
      res.notes[#res.notes + 1] = string.format("%d new in the calendar, not added: it has no inbox", #inserts)
    else
      local level, after = entry.target(inbox_buf, inbox.headline)
      local file = files.get_buffer(inbox_buf)
      local lines = {}
      for _, ins in ipairs(inserts) do
        vim.list_extend(lines, entry.lines(file, level, ins.src.type, ins.uid, ins.src.fields))
      end
      entry.insert(inbox_buf, after, lines)
      touched[inbox_buf] = true
      for _, ins in ipairs(inserts) do
        local src = ins.src
        where[ins.uid] = inbox_buf
        local lf = local_fields(ins.uid, src.type) or src.fields
        st.items[ins.uid] = {
          href = src.href,
          etag = src.etag,
          ics = src.ics,
          type = src.type,
          base = base_of(lf, src.type),
          ro = next(src.ro) ~= nil or nil,
        }
        res.pulled = res.pulled + 1
      end
    end
  end

  if e.opts().save then
    for b in pairs(touched) do
      utils().save_buffer_or_warn(b)
    end
  end
  return plan, nil
end

---@param c org.caldav.Calendar
---@param run { interactive: boolean }
---@return org.caldav.Result
function M.sync_calendar(c, run)
  ---@type org.caldav.Result
  local res = {
    name = c.name,
    pulled = 0,
    pushed = 0,
    deleted_local = 0,
    deleted_remote = 0,
    conflicts = 0,
    errors = {},
    notes = {},
  }
  local e = ext()
  local todos = e.opt(c, "todos") == true
  local ctx = M.context(c)
  local paths, perr = e.files_of(c)
  if not paths then
    res.failed = perr
    return res
  end
  local st = M.load_state(c)
  -- what was left out depends on these options: with other values it is
  -- looked at again
  local sig = table.concat({ tostring(ctx.past), tostring(todos), tostring(e.opt(c, "direction")) }, "|")
  if st.sig ~= sig then
    st.sig, st.skipped = sig, {}
  end

  -- 1. what the server has
  local start = ctx.past and ical.utc(ical.epoch((ctx.today - ctx.past) * 86400, ctx)) or nil
  local win, err = http.query(c, "VEVENT", start)
  if not win then
    res.failed = err
    return res
  end
  if todos then
    local tasks, terr = http.query(c, "VTODO")
    if not tasks then
      res.failed = terr
      return res
    end
    for href, etag in pairs(tasks) do
      win[href] = etag
    end
  end
  -- an event that is no longer in the days asked for may still exist
  local all = win
  if start then
    for _, it in pairs(st.items) do
      if not win[it.href] then
        local every, eerr = http.etags(c)
        if not every then
          res.failed = eerr
          return res
        end
        all = every
        break
      end
    end
  end
  local by_href = {}
  for uid, it in pairs(st.items) do
    by_href[it.href] = uid
  end
  local want = {}
  for href, etag in pairs(win) do
    local uid = by_href[href]
    if uid then
      if st.items[uid].etag ~= etag then
        want[#want + 1] = href
      end
    elseif st.skipped[href] ~= etag then
      want[#want + 1] = href
    end
  end
  for _, it in pairs(st.items) do
    if not win[it.href] and all[it.href] and all[it.href] ~= it.etag then
      want[#want + 1] = it.href
    end
  end
  table.sort(want)
  local data = {}
  if #want > 0 then
    local got, gerr = http.multiget(c, want)
    if not got then
      res.failed = gerr
      return res
    end
    data = got
  end
  ---@type table<string, org.caldav.Fetched>
  local remote = {}
  local hrefs = vim.tbl_keys(data)
  table.sort(hrefs)
  for _, href in ipairs(hrefs) do
    local d = data[href]
    local r = ical.read(d.ics, ctx)
    if not r or (r.type == "VTODO" and not todos and not st.items[r.uid]) or remote[r.uid] then
      st.skipped[href] = d.etag
    else
      remote[r.uid] = { href = href, etag = d.etag, ics = d.ics, type = r.type, fields = r.fields, ro = r.ro }
    end
  end

  -- 2. the org files
  local plan, rerr = reconcile(c, st, all, remote, ctx, res, run, paths)
  if not plan then
    res.failed = rerr
    return res
  end
  M.save_state(c, st)

  -- 3. what the server gets
  for _, p in ipairs(plan.pushes) do
    local etag, perr2, status = http.put(c, p.href, p.ics, p.etag)
    if not etag then
      if status == 412 and not p.etag then
        perr2 = "something else is stored under its ID in the calendar"
      end
      res.errors[#res.errors + 1] = string.format('"%s": not sent: %s', p.title, perr2 or "")
    else
      local ics = p.ics
      if etag == "" then
        -- no etag in the reply: the server may have rewritten it
        local got = http.multiget(c, { p.href })
        local stored = got and got[p.href]
        if stored then
          etag, ics = stored.etag, stored.ics
        end
      end
      st.items[p.uid] = { href = p.href, etag = etag, ics = ics, type = p.type, base = p.base, ro = p.ro }
      res.pushed = res.pushed + 1
    end
  end
  for _, d in ipairs(plan.deletes) do
    local ok, derr = http.delete(c, d.href, d.etag)
    if ok then
      st.items[d.uid] = nil
      res.deleted_remote = res.deleted_remote + 1
    else
      res.errors[#res.errors + 1] = string.format('"%s": not deleted from the calendar: %s', d.title, derr or "")
    end
  end
  st.synced = os.time()
  M.save_state(c, st)
  return res
end

---------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------

--- One line saying what a sync did, then its notes and errors.
---@param res org.caldav.Result
---@return string text, boolean trouble
function M.summary(res)
  if res.failed then
    return string.format("caldav: %s: %s", res.name, res.failed), true
  end
  local parts = {}
  local function add(n, what)
    if n > 0 then
      parts[#parts + 1] = n .. " " .. what
    end
  end
  add(res.pulled, "from the calendar")
  add(res.pushed, "to the calendar")
  add(res.deleted_local, "deleted here")
  add(res.deleted_remote, "deleted in the calendar")
  local lines = { string.format("caldav: %s: %s", res.name, #parts > 0 and table.concat(parts, ", ") or "up to date") }
  for _, n in ipairs(res.errors) do
    lines[#lines + 1] = "  " .. n
  end
  for _, n in ipairs(res.notes) do
    lines[#lines + 1] = "  " .. n
  end
  return table.concat(lines, "\n"), #res.errors > 0
end

--- Whether a sync changed anything.
---@param res org.caldav.Result
---@return boolean
local function changed(res)
  return res.pulled + res.pushed + res.deleted_local + res.deleted_remote > 0
end

local running = false
-- calendar name -> the trouble last reported by a sync nobody asked for
local warned = {}

--- The results of the last sync of each calendar, by name.
---@type table<string, { time: integer, result: org.caldav.Result }>
M.last = {}

--- Whether a sync is running.
---@return boolean
function M.running()
  return running
end

--- Sync the calendars (`only`: the one of that name). `opts.auto`: nobody
--- asked (the timer): no questions, and a message only when something
--- changed or went wrong. `opts.done(results)` is called at the end.
---@param only? string
---@param opts? { auto?: boolean, done?: fun(results: org.caldav.Result[]|nil) }
function M.run(only, opts)
  opts = opts or {}
  local u = utils()
  local function finish(results)
    if opts.done then
      opts.done(results)
    end
  end
  if running then
    if not opts.auto then
      u.warn("caldav: a sync is already running")
    end
    return finish(nil)
  end
  local cals = {}
  for _, c in ipairs(ext().calendars()) do
    if only == nil or c.name == only then
      cals[#cals + 1] = c
    end
  end
  if #cals == 0 then
    if not opts.auto then
      u.warn(
        only and ("caldav: no calendar named " .. only) or "caldav: no calendars (set extensions.caldav.calendars)"
      )
    end
    return finish(nil)
  end
  running = true
  u.run(function()
    local results = {}
    for _, c in ipairs(cals) do
      local ok, res = pcall(M.sync_calendar, c, { interactive = not opts.auto })
      if not ok then
        res = {
          name = c.name,
          pulled = 0,
          pushed = 0,
          deleted_local = 0,
          deleted_remote = 0,
          conflicts = 0,
          errors = {},
          notes = {},
          failed = tostring(res),
        }
      end
      results[#results + 1] = res
      M.last[c.name] = { time = os.time(), result = res }
      local text, trouble = M.summary(res)
      trouble = trouble or res.failed ~= nil
      if not opts.auto then
        if trouble then
          u.warn(text)
        else
          u.notify(text)
        end
      else
        -- nobody asked: one line (more would stop the user at a Press
        -- ENTER), and the same trouble only once
        local line = text:match("^[^\n]*")
        local more = #res.errors + #res.notes
        if more > 0 then
          line = string.format("%s (%d note%s: :Org caldav_sync shows them)", line, more, more == 1 and "" or "s")
        end
        if trouble then
          if warned[c.name] ~= text then
            warned[c.name] = text
            u.warn(line)
          end
        else
          warned[c.name] = nil
          if changed(res) then
            u.notify(line)
          end
        end
      end
    end
    running = false
    local any = false
    for _, res in ipairs(results) do
      any = any or changed(res)
    end
    if any then
      local ok, view = pcall(require, "org.agenda.view")
      if ok then
        pcall(view.redo)
      end
    end
    finish(results)
  end)
end

--- Forget what the timer warned about (a new setup).
function M.reset()
  warned = {}
  M.last = {}
end

return M
