-- org-protocol URLs (org-protocol.el).
local config = require("org.config")
local protocol = require("org.protocol")
local utils = require("org.utils")

vim.g.org_test = true

local function quiet(fn)
  local n, w = utils.notify, utils.warn
  utils.notify, utils.warn = function() end, function() end
  local ok, err = pcall(fn)
  utils.notify, utils.warn = n, w
  if not ok then
    error(err, 0)
  end
end

describe("org-protocol", function()
  it("parses new-style queries and old-style paths", function()
    eq({ url = "https://a.b/c?d=1", title = "A title" }, protocol.parse_query("url=https%3A%2F%2Fa.b%2Fc%3Fd%3D1&title=A+title"))
    eq({ url = "u", title = "t", extra = "x" }, protocol.parse_old_style("u/t/extra/x", { "url", "title" }))
    eq("https://a.b/c", protocol.sanitize_uri("https:/a.b//c"))
  end)

  it("store-link stores the URL and title", function()
    quiet(function()
      ok(protocol.handle("org-protocol://store-link?url=https%3A%2F%2Fexample.com%2Fp&title=Example+Page"))
    end)
    local s = require("org.links").stored[1]
    eq("https://example.com/p", s.link)
    eq("Example Page", s.desc)
    eq("https://example.com/p", vim.fn.getreg('"'))
    -- old style
    quiet(function()
      protocol.handle("org-protocol://store-link://https%3A%2F%2Fold.org/Old")
    end)
    eq("https://old.org", require("org.links").stored[1].link)
  end)

  it("capture fills %:link %:description %a %i from the URL", function()
    local target = vim.fn.tempname() .. ".org"
    utils.writefile(target, { "* Inbox" })
    local saved = config.opts.capture.templates
    config.opts.capture.templates = {
      p = {
        description = "Protocol",
        target = target,
        template = "* %:description\n%:link\n%i\n%a",
        immediate_finish = true,
      },
    }
    quiet(function()
      ok(protocol.handle("org-protocol://capture?template=p&url=https%3A%2F%2Fex.com&title=Ex+Title&body=selected+text"))
      -- old style with a one-letter template key first
      ok(protocol.handle("org-protocol://capture://p/https%3A%2F%2Fold.com/Old/body"))
    end)
    config.opts.capture.templates = saved
    local l = vim.api.nvim_buf_get_lines(utils.find_buffer(target), 0, -1, false)
    local text = table.concat(l, "\n")
    ok(text:find("* Ex Title\nhttps://ex.com\nselected text\n[[https://ex.com][Ex Title]]", 1, true), text)
    ok(text:find("* Old\nhttps://old.com\nbody\n[[https://old.com][Old]]", 1, true), text)
  end)

  it("open-source maps published URLs to local files", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/notes", "p")
    utils.writefile(dir .. "/notes/page.org", { "* Page" })
    local saved = config.opts.protocol.projects
    config.opts.protocol.projects = {
      {
        base_url = "https://example.com/site/",
        working_directory = dir .. "/",
        online_suffix = ".html",
        working_suffix = ".org",
      },
    }
    local f
    quiet(function()
      f = protocol.handle("org-protocol://open-source?url=https%3A%2F%2Fexample.com%2Fsite%2Fnotes%2Fpage.html%23sec")
    end)
    config.opts.protocol.projects = saved
    eq(dir .. "/notes/page.org", f)
    eq("* Page", vim.api.nvim_get_current_line())
  end)

  it("custom sub-protocols", function()
    local got
    config.opts.protocol.handlers = {
      {
        protocol = "hello",
        fn = function(p)
          got = p
          return true
        end,
      },
    }
    ok(protocol.handle("org-protocol://hello?name=World"))
    config.opts.protocol.handlers = {}
    eq({ name = "World" }, got)
    quiet(function()
      eq(nil, protocol.handle("org-protocol://unknown?x=1"))
      eq(nil, protocol.handle("https://not-protocol"))
    end)
  end)
end)
