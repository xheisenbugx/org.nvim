-- Following links: org-follow-link-hook (OrgFollowLink), org-tab-follows-link,
-- org-open-directory-means-index-dot-org, org-open-non-existing-files,
-- org-open-at-point-global, org-occur-link-in-agenda-files and the mouse
-- (org-open-at-mouse, org-find-file-at-mouse, org-mouse-1-follows-link).
local config = require("org.config")
local links = require("org.links")

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir)
end

local function stub(tbl, name, value)
  local old = tbl[name]
  tbl[name] = value
  return function()
    tbl[name] = old
  end
end

local function quiet(fn)
  local notify = vim.notify
  local msgs = {}
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert(ok, err)
  return msgs
end

describe("following links", function()
  local saved_links
  before_each(function()
    saved_links = vim.deepcopy(config.opts.links)
  end)
  after_each(function()
    config.opts.links = saved_links
  end)

  describe("OrgFollowLink (org-follow-link-hook)", function()
    it("fires after a link is followed, not when there is none", function()
      local fired = 0
      local au = vim.api.nvim_create_autocmd("User", {
        pattern = "OrgFollowLink",
        callback = function()
          fired = fired + 1
        end,
      })
      org_buffer({ "* A", "see [[B]]", "* B" }, { 2, 6 })
      require("org.context").open_at_point()
      eq(3, vim.api.nvim_win_get_cursor(0)[1])
      eq(1, fired)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      eq(false, require("org.context").open_at_point())
      eq(1, fired)
      vim.api.nvim_del_autocmd(au)
    end)
  end)

  describe("tab_follows_link (org-tab-follows-link)", function()
    it("follows the link under the cursor instead of cycling", function()
      org_buffer({ "* A", "see [[B]]", "* B" }, { 2, 6 })
      require("org.fold").cycle()
      eq(2, vim.api.nvim_win_get_cursor(0)[1])
      config.opts.links.tab_follows_link = true
      require("org.fold").cycle()
      eq(3, vim.api.nvim_win_get_cursor(0)[1])
    end)
  end)

  describe("file links", function()
    it("open a directory's index.org with open_directory_means_index_dot_org", function()
      local dir = tmpdir()
      vim.fn.writefile({ "* Index" }, dir .. "/index.org")
      config.opts.links.frame_setup = { file = "current" }
      org_buffer({ "x" }, { 1, 0 })
      vim.bo.modified = false
      links.open("file:" .. dir)
      eq(dir, vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) or vim.api.nvim_buf_get_name(0):gsub("/$", ""))
      org_buffer({ "x" }, { 1, 0 })
      vim.bo.modified = false
      config.opts.links.open_directory_means_index_dot_org = true
      links.open("file:" .. dir)
      eq(dir .. "/index.org", vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
    end)

    it("refuse missing files for external apps unless open_non_existing_files", function()
      local dir = tmpdir()
      local opened = {}
      config.opts.links.file_apps = {
        pdf = function(path)
          opened[#opened + 1] = path
        end,
      }
      org_buffer({ "x" }, { 1, 0 })
      local msgs = quiet(function()
        links.open("file:" .. dir .. "/missing.pdf")
      end)
      eq({}, opened)
      eq("No such file: " .. dir .. "/missing.pdf", msgs[#msgs]:gsub("^org: ", ""))
      vim.fn.writefile({ "" }, dir .. "/there.pdf")
      links.open("file:" .. dir .. "/there.pdf")
      eq({ dir .. "/there.pdf" }, opened)
      config.opts.links.open_non_existing_files = true
      links.open("file:" .. dir .. "/missing.pdf")
      eq({ dir .. "/there.pdf", dir .. "/missing.pdf" }, opened)
    end)
  end)

  describe("open_at_point_global (org-open-at-point-global)", function()
    local function text_buffer(lines, cursor)
      local buf = vim.api.nvim_create_buf(true, true)
      vim.bo.modified = false
      vim.api.nvim_set_current_buf(buf)
      vim.bo[buf].filetype = "text"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_win_set_cursor(0, cursor)
      return buf
    end

    it("follows Org links, URLs and e-mail addresses in any buffer", function()
      local opened = {}
      local restore = stub(vim.ui, "open", function(u)
        opened[#opened + 1] = u
      end)
      text_buffer({
        "see [[https://orgmode.org/manual][the manual]] now",
        "plain https://example.com/a/b. end",
        "write to bob@example.com please",
        "<https://angle.example/x> ok",
      }, { 1, 12 })
      links.open_at_point_global()
      vim.api.nvim_win_set_cursor(0, { 2, 12 })
      links.open_at_point_global()
      vim.api.nvim_win_set_cursor(0, { 3, 12 })
      links.open_at_point_global()
      vim.api.nvim_win_set_cursor(0, { 4, 3 })
      links.open_at_point_global()
      restore()
      eq({
        "https://orgmode.org/manual",
        "https://example.com/a/b",
        "mailto:bob@example.com",
        "https://angle.example/x",
      }, opened)
    end)

    it("opens the agenda of a timestamp and reports when there is nothing", function()
      local agenda = require("org.agenda")
      local day
      local restore = stub(agenda, "open_day", function(d)
        day = d:to_date_string()
      end)
      text_buffer({ "meeting <2026-10-01 Thu 10:00> here", "nothing" }, { 1, 12 })
      eq(true, links.open_at_point_global())
      eq("2026-10-01", day)
      vim.api.nvim_win_set_cursor(0, { 2, 2 })
      local r
      quiet(function()
        r = links.open_at_point_global()
      end)
      eq(false, r)
      restore()
    end)

    it("is an action available outside Org buffers", function()
      local a = require("org.actions").list.open_at_point_global
      ok(a and a.global)
    end)
  end)

  describe("occur_link_in_agenda_files (org-occur-link-in-agenda-files)", function()
    it("lists the lines holding the link to here", function()
      -- Emacs 9.8.10 (probe occurlink.el): the search is for the link
      -- org-store-link makes, "[[file:A::*Target heading][Target heading]]";
      -- only the line with that exact link matches
      local dir = tmpdir()
      local a, b = dir .. "/a.org", dir .. "/b.org"
      vim.fn.writefile({ "* Target heading", "text" }, a)
      local saved = config.opts.agenda_files
      config.opts.agenda_files = { a, b }
      vim.cmd("edit! " .. vim.fn.fnameescape(a))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local l = links.link_to_location({})
      vim.fn.writefile({
        "* Refs",
        links.format(l.link, l.desc),
        "[[" .. l.link .. "]]",
        "[[file:a.org::*Target heading][Target heading]]",
      }, b)
      quiet(function()
        links.occur_link_in_agenda_files()
      end)
      config.opts.agenda_files = saved
      local items = vim.fn.getqflist()
      pcall(vim.cmd, "cclose")
      eq(1, #items)
      eq(2, items[1].lnum)
      eq(vim.uv.fs_realpath(b), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(items[1].bufnr)))
      eq("[[file:" .. l.link:gsub("^file:", "") .. "][Target heading]]", items[1].text)
    end)
  end)

  describe("mouse", function()
    local mouse = require("org.mouse")

    it("<MiddleMouse> and <RightMouse> open the link clicked", function()
      local args = {}
      local restore_open = stub(links, "open_at_point", function(arg)
        args[#args + 1] = arg
        return true
      end)
      local restore_point = stub(mouse, "_mouse_set_point", function()
        vim.api.nvim_win_set_cursor(0, { 2, 6 })
        return true
      end)
      org_buffer({ "* A", "see [[B]] or not", "* B" }, { 1, 0 })
      eq(true, mouse.open_at_mouse())
      eq(true, mouse.find_file_at_mouse())
      -- org-find-file-at-mouse: org-open-at-point 'in-emacs
      eq({ 0, 4 }, args)
      mouse._mouse_set_point = function()
        vim.api.nvim_win_set_cursor(0, { 2, 14 })
        return true
      end
      eq(false, mouse.open_at_mouse())
      restore_point()
      restore_open()
      eq("<MiddleMouse>", config.opts.mappings.org.open_at_mouse)
      eq("<RightMouse>", config.opts.mappings.org.find_file_at_mouse)
    end)

    it("a short click follows a link (mouse_1_follows_link)", function()
      eq(true, mouse.click_follows(450, { time = 0, row = 2, col = 5 }, { time = 200, row = 2, col = 5 }))
      eq(false, mouse.click_follows(450, { time = 0, row = 2, col = 5 }, { time = 600, row = 2, col = 5 }))
      eq(false, mouse.click_follows(450, { time = 0, row = 2, col = 5 }, { time = 10, row = 2, col = 9 }))
      eq(true, mouse.click_follows(true, { time = 0, row = 2, col = 5 }, { time = 9000, row = 2, col = 5 }))
      eq(false, mouse.click_follows(false, { time = 0, row = 2, col = 5 }, { time = 10, row = 2, col = 5 }))
      eq(false, mouse.click_follows("double", { time = 0, row = 2, col = 5 }, { time = 10, row = 2, col = 5 }))
      org_buffer({ "* A", "see [[B]]", "* B" }, { 2, 6 })
      mouse._press = { time = 0, row = 1, col = 1 }
      mouse._after_release({ time = 100, row = 1, col = 1 })
      eq(3, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_win_set_cursor(0, { 2, 6 })
      mouse._press = { time = 0, row = 1, col = 1 }
      mouse._after_release({ time = 1000, row = 1, col = 1 })
      eq(2, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("maps the click keys the option asks for", function()
      local function maps(buf)
        local out = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
          -- clicks (<MouseMove> highlights citation keys)
          if (m.lhs:find("Mouse") or m.lhs:find("Release")) and m.lhs ~= "<MouseMove>" then
            out[#out + 1] = m.lhs
          end
        end
        table.sort(out)
        return out
      end
      local buf = vim.api.nvim_create_buf(false, true)
      mouse.attach(buf)
      eq({ "<LeftMouse>", "<LeftRelease>" }, maps(buf))
      config.opts.links.mouse_1_follows_link = "double"
      buf = vim.api.nvim_create_buf(false, true)
      mouse.attach(buf)
      -- <LeftRelease> stays for citation keys, whose click does not depend on
      -- the option (oc-basic binds <mouse-1> on the key)
      eq({ "<2-LeftMouse>", "<LeftRelease>" }, maps(buf))
      config.opts.links.mouse_1_follows_link = false
      buf = vim.api.nvim_create_buf(false, true)
      mouse.attach(buf)
      eq({ "<LeftRelease>" }, maps(buf))
    end)
  end)
end)
