-- Remote resources: resource_download_policy and safe_remote_resources
-- (org-resource-download-policy, org-safe-remote-resources) for remote
-- #+INCLUDE files. Expectations from Emacs 9.8.10 (probe resource.el):
-- the domain Emacs offers to trust, which URLs each policy fetches (a safe
-- URL is fetched even with the policy nil) and the refusal message.
local config = require("org.config")
local resources = require("org.resources")

local function stub(tbl, name, value)
  local old = tbl[name]
  tbl[name] = value
  return function()
    tbl[name] = old
  end
end

describe("remote resources", function()
  local restore_download, downloads
  before_each(function()
    resources._reset()
    os.remove(vim.fn.stdpath("data") .. "/org/safe-remote-resources.json")
    downloads = {}
    restore_download = stub(resources, "_download", function(uri)
      downloads[#downloads + 1] = uri
      return "* Remote\ntext from " .. uri .. "\n"
    end)
  end)
  after_each(function()
    restore_download()
    config.opts.resource_download_policy = "prompt"
    config.opts.safe_remote_resources = {}
    resources._reset()
  end)

  --- Answer the prompt with `keys`; returns the float's text.
  local function answer(keys, fn)
    local shown
    local restore = stub(vim.fn, "getcharstr", function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          shown = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
        end
      end
      return table.remove(keys, 1) or "\27"
    end)
    local ok, res = pcall(fn)
    restore()
    assert(ok, res)
    return res, shown
  end

  it("finds the domain Emacs offers to trust", function()
    eq("https://www.example.com", resources.domain("https://www.example.com/a/b.org"))
    eq("http://user@host.org", resources.domain("http://user@host.org:8080/x"))
    eq("https://example.com", resources.domain("https://example.com?q=1"))
    eq(nil, resources.domain("ftp://x.org/a"))
  end)

  it("fetches per policy; safe URLs even with the policy false", function()
    config.opts.safe_remote_resources = { "^https://safe\\.example/" }
    local getcharstr = stub(vim.fn, "getcharstr", function()
      error("must not prompt")
    end)
    for _, policy in ipairs({ true, "safe", false }) do
      config.opts.resource_download_policy = policy
      eq(true, resources.should_fetch("https://safe.example/x.org"))
      eq(policy == true, resources.should_fetch("https://bad.example/x.org"))
    end
    getcharstr()
  end)

  it("refuses unsafe includes with Emacs's message", function()
    config.opts.resource_download_policy = "safe"
    local lines, err = resources.contents("https://bad.example/x.org")
    eq(nil, lines)
    eq('The remote resource "https://bad.example/x.org" is considered unsafe, and will not be downloaded.', err)
    eq({}, downloads)
    local ok_, e = pcall(require("org.export.ox").export_as, "html", { "#+INCLUDE: https://bad.example/x.org" }, {})
    eq(false, ok_)
    ok(tostring(e):find("considered unsafe", 1, true))
  end)

  it("asks before downloading, once per session", function()
    local res, shown = answer({ "q", "y" }, function()
      return resources.contents("https://bad.example/x.org", "/tmp/doc.org")
    end)
    eq({ "* Remote", "text from https://bad.example/x.org" }, res)
    ok(shown:find("An org-mode document would like to download https://bad.example/x.org", 1, true))
    ok(shown:find(" d to download this resource, and mark the domain (https://bad.example) as safe.", 1, true))
    ok(shown:find(" f to download this resource, and permanently mark all resources in ", 1, true))
    -- cached (org--file-cache): no second prompt or download
    answer({}, function()
      resources.contents("https://bad.example/x.org")
    end)
    eq(1, #downloads)
    -- "y" is not remembered
    resources._cache = {}
    local refused = answer({ "n" }, function()
      return resources.contents("https://bad.example/x.org")
    end)
    eq(nil, refused)
  end)

  it("remembers !, d and f answers", function()
    answer({ "!" }, function()
      return resources.should_fetch("https://a.example/one.org")
    end)
    eq(true, resources.is_safe("https://a.example/one.org"))
    eq(false, resources.is_safe("https://a.example/one.org.bak"))
    answer({ "d" }, function()
      return resources.should_fetch("https://b.example/one.org")
    end)
    eq(true, resources.is_safe("https://b.example/other.org"))
    eq(true, resources.is_safe("https://b.example"))
    eq(false, resources.is_safe("https://b.example.evil/x"))
    local doc = vim.fn.tempname() .. ".org"
    vim.fn.writefile({ "" }, doc)
    answer({ "f" }, function()
      return resources.should_fetch("https://c.example/x.org", doc)
    end)
    eq(true, resources.is_safe("https://anything.example/y.org", doc))
    eq(false, resources.is_safe("https://anything.example/y.org"))
    -- saved across sessions
    resources._reset()
    eq(true, resources.is_safe("https://b.example/z"))
  end)

  it("includes an allowed remote file in the export", function()
    config.opts.resource_download_policy = true
    local html = require("org.export.ox").export_as("html", { "#+INCLUDE: https://ok.example/x.org" }, {})
    ok(tostring(html):find("Remote</h2>", 1, true))
    ok(tostring(html):find("text from ", 1, true))
  end)
end)
