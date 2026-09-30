-- Shared part of the demo configs of the view extensions (kanban.lua,
-- timeline.lua, heatmap.lua, sidebar.lua): runs init.lua, then copies
-- views/*.org to $ORG_DEMO_DIR/views with the same {{N}} and {{now+N}}
-- date expansion. Returns that directory.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")

local dir = (vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo") .. "/views"
vim.fn.mkdir(dir, "p")
for _, src in ipairs(vim.fn.glob(here .. "/views/*.org", false, true)) do
  local text = table.concat(vim.fn.readfile(src), "\n")
  text = text:gsub("{{now%+(%d+)}}", function(minutes)
    return os.date("%Y-%m-%d %a %H:%M", os.time() + tonumber(minutes) * 60)
  end)
  text = text:gsub("{{(%-?%d+)%s*([%d:%-]*)}}", function(offset, time)
    local date = os.date("%Y-%m-%d %a", os.time() + tonumber(offset) * 86400)
    return time ~= "" and (date .. " " .. time) or date
  end)
  vim.fn.writefile(vim.split(text, "\n"), dir .. "/" .. vim.fn.fnamemodify(src, ":t"))
end
return dir
