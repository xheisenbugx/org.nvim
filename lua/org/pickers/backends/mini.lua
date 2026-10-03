--- mini.pick backend (MiniPick.start). Needs `require("mini.pick").setup()`.
--- Items carry `path`/`bufnr` and `lnum`/`col`, which the default preview
--- shows; `show` adds the display highlights over the default one. With
--- `allow_query` a "+ New" entry takes the typed query.
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
---@param finish fun(items?: org.PickerItem[], query?: string)
function M.pick(spec, finish)
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
  local chosen, query
  local function query_text()
    local ok, q = pcall(MiniPick.get_picker_query)
    return ok and type(q) == "table" and vim.trim(table.concat(q)) or nil
  end
  local function take(list)
    local out = {}
    for _, x in ipairs(list) do
      if x.create then
        query = query_text()
      elseif x.org_idx then
        out[#out + 1] = spec.items[x.org_idx]
      end
    end
    chosen = out
  end
  MiniPick.start({
    source = {
      name = spec.title,
      items = items,
      show = function(buf, shown, q)
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
          return MiniPick.default_preview(buf, x)
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { x.text })
      end,
      choose = function(x)
        take({ x })
      end,
      choose_marked = function(marked)
        take(spec.multi and marked or { marked[1] })
      end,
    },
  })
  if chosen and (#chosen > 0 or (query and query ~= "")) then
    finish(chosen, query)
  elseif chosen and query then
    -- "+ New" with nothing typed: ask for it
    utils.run(function()
      local text = vim.trim(utils.input({ prompt = pickers.create_prompt(spec) }) or "")
      finish(text ~= "" and {} or nil, text)
    end)
  else
    finish(nil)
  end
end

return M
