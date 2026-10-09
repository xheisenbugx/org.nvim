--- mini.pick backend (MiniPick.start). Needs `require("mini.pick").setup()`.
--- Items carry `path`/`bufnr` and `lnum`/`col`, which the default preview
--- shows; `show` adds the display highlights over the default one. With
--- `allow_query` a "+ New" entry, listed whatever is typed, takes the
--- typed text.
local pickers = require("org.pickers")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.pickers.mini")

local function api()
  local P = rawget(_G, "MiniPick")
  if type(P) == "table" and type(P.start) == "function" then
    return P
  end
end

function M.available()
  return api() ~= nil
end

---@param spec org.PickerSpec
---@param finish fun(items?: org.PickerItem[], query?: string, how?: org.PickerHow)
---@param user? table `picker_opts.mini`, merged under org.nvim's source
function M.pick(spec, finish, user)
  local MiniPick = api()
  local items = {}
  local create
  if spec.allow_query then
    create = { text = spec.create_label or "+ New…", create = true }
    items[1] = create
  end
  for i, it in ipairs(spec.items) do
    items[#items + 1] = {
      text = pickers.line(it):gsub("\n", " "),
      path = it.filename,
      bufnr = not it.filename and it.bufnr or nil,
      lnum = it.lnum,
      col = it.lnum and it.col or nil,
      -- an index, not the item: mini.pick deep-copies the items (and a
      -- headline links to its parent and children)
      org_idx = i,
    }
  end
  -- "+ New tags…" with the text typed: "+ New tags: work"
  local function create_text(typed)
    if typed == "" then
      return create.text
    end
    return (create.text:gsub("…$", "")) .. ": " .. typed
  end
  -- "+ New" (index 1) is never matched by its own label: it stays listed,
  -- first while nothing is typed, then below the matches, so <CR> creates
  -- from a text that matches nothing
  local match
  if create then
    match = function(stritems, inds, query)
      if #query == 0 then
        local all = {}
        for i = 1, #stritems do
          all[i] = i
        end
        return all
      end
      local rest = {}
      for _, i in ipairs(inds) do
        if i ~= 1 then
          rest[#rest + 1] = i
        end
      end
      local found = MiniPick.default_match(stritems, rest, query, { sync = true })
      if not found then
        -- interrupted by a newer query (matching while items load): keep
        -- the matches of that one
        return nil
      end
      found[#found + 1] = 1
      return found
    end
  end
  local function query_text()
    local ok, q = pcall(MiniPick.get_picker_query)
    return ok and type(q) == "table" and vim.trim(table.concat(q)) or nil
  end
  -- Answer when entries are chosen, also in a run of
  -- MiniPick.builtin.resume() (start() has returned by then). The answer
  -- comes once the picker has stopped.
  local answered = false
  local function take(list, how)
    answered = true
    local out, new = {}, false
    for _, x in ipairs(list) do
      if x.create then
        new = true
      elseif x.org_idx then
        out[#out + 1] = spec.items[x.org_idx]
      end
    end
    local query = new and query_text() or nil
    if new and #out == 0 and (query or "") == "" then
      -- "+ New" with nothing typed: ask for it
      vim.schedule(function()
        utils.run(function()
          local text = vim.trim(utils.input({ prompt = pickers.create_prompt(spec) }) or "")
          finish(text ~= "" and {} or nil, text)
        end)
      end)
      return
    end
    finish(out, query, how)
  end
  -- the picker_keys replace mini.pick's choose_in_split / vsplit / tabpage,
  -- which split before choosing; qflist chooses the marked items, or every
  -- match when none is marked
  local mappings = {}
  local keys = pickers.split_keys(spec)
  if #keys > 0 then
    mappings = { choose_in_split = "", choose_in_vsplit = "", choose_in_tabpage = "" }
    for _, k in ipairs(keys) do
      local how = k[1]
      mappings["org_" .. how] = {
        char = k[2],
        func = function()
          local ok, matches = pcall(MiniPick.get_picker_matches)
          matches = ok and type(matches) == "table" and matches or {}
          if how == "qflist" then
            local list = matches.marked and #matches.marked > 0 and matches.marked or matches.all
            if list and #list > 0 then
              take(list, how)
            end
          elseif matches.current then
            take({ matches.current }, how)
          end
          -- stop the picker
          return true
        end,
      }
    end
  end
  local source_items = items
  if spec.query and spec.query ~= "" then
    -- start with the query typed: called once the picker is active
    source_items = function()
      MiniPick.set_picker_query(vim.fn.split(spec.query, "\\zs"))
      return items
    end
  end
  MiniPick.start(vim.tbl_deep_extend("force", user or {}, {
    mappings = mappings,
    source = {
      name = spec.title,
      items = source_items,
      match = match,
      show = function(buf, shown, q)
        local typed = vim.trim(table.concat(q or {}))
        if create and typed ~= "" then
          shown = vim.tbl_map(function(x)
            return x.create and { text = create_text(typed), create = true } or x
          end, shown)
        end
        MiniPick.default_show(buf, shown, q)
        pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
        for row, x in ipairs(shown) do
          local col = 0
          local it = x.org_idx and spec.items[x.org_idx]
          for _, c in ipairs(it and it.display or {}) do
            local len = #c[1]:gsub("\n", " ")
            if c[2] and len > 0 then
              pcall(vim.api.nvim_buf_set_extmark, buf, ns, row - 1, col, {
                end_col = col + len,
                hl_group = c[2],
                priority = 150,
              })
            end
            col = col + len
          end
        end
      end,
      preview = function(buf, x)
        if spec.preview and (x.path or x.bufnr) then
          -- the buffer when the file is loaded
          local b = pickers.buffer(spec.items[x.org_idx])
          return MiniPick.default_preview(buf, b and vim.tbl_extend("force", x, { bufnr = b }) or x)
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { x.create and create_text(query_text() or "") or x.text })
      end,
      choose = function(x)
        take({ x })
      end,
      choose_marked = function(marked)
        take(spec.multi and marked or { marked[1] })
      end,
    },
  }))
  if not answered then
    finish(nil)
  end
end

return M
