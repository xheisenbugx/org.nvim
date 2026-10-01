-- org-protocol-data-separator, org-protocol-create and
-- org-protocol-create-for-org.
local config = require("org.config")
local protocol = require("org.protocol")
local utils = require("org.utils")
vim.g.org_test = true

local function answer(list)
  local orig = { utils.input, utils.confirm, utils.notify }
  local prompts = {}
  utils.input = function(opts)
    prompts[#prompts + 1] = { opts.prompt, opts.default }
    return table.remove(list, 1)
  end
  utils.confirm = function(q)
    prompts[#prompts + 1] = { q }
    return table.remove(list, 1)
  end
  utils.notify = function() end
  return prompts, function()
    utils.input, utils.confirm, utils.notify = unpack(orig)
  end
end

describe("protocol.data_separator (org-protocol-data-separator)", function()
  after_each(function()
    config.setup({})
  end)

  it("splits old-style data like Emacs, keeping empty parts", function()
    config.setup({})
    -- Emacs 9.8.10: (org-protocol-split-data "a/?b//c/" t org-protocol-data-separator)
    -- => ("a" "" "b" "c" "")
    eq({ url = "a", title = "", body = "b", c = "" }, protocol.parse_old_style("a/?b//c/", { "url", "title", "body" }))
    -- Emacs 9.8.10 with separator "|": (:url "https://a.b/c" :title "Title" :body "body/with/slash")
    config.setup({ protocol = { data_separator = [[|]] } })
    eq(
      { url = "https://a.b/c", title = "Title", body = "body/with/slash" },
      protocol.parse_old_style("https%3A%2F%2Fa.b%2Fc|Title|body/with/slash", { "url", "title", "body" })
    )
  end)
end)

describe("protocol_create (org-protocol-create)", function()
  after_each(function()
    config.setup({})
  end)

  it("asks for the project and adds it for the session", function()
    config.setup({})
    local prompts, restore = answer({ "https://example.com/site", "/tmp/site", "", ".txt", true })
    local entry = protocol.create()
    restore()
    eq("Base URL of published content: ", prompts[1][1])
    eq("https://orgmode.org/worg/", prompts[1][2])
    eq("Extension to strip from published URLs (.html): ", prompts[3][1])
    eq("Extension of editable files (.org): ", prompts[4][1])
    local want = {
      base_url = "https://example.com/site/",
      working_directory = "/tmp/site/",
      online_suffix = ".html",
      working_suffix = ".txt",
    }
    eq(want, entry)
    eq(want, config.opts.protocol.projects[1])
  end)

  it("adds nothing when not confirmed", function()
    config.setup({})
    local _, restore = answer({ "", "", "", "", false })
    eq(nil, protocol.create())
    restore()
    eq({}, config.opts.protocol.projects)
  end)

  it("takes the defaults from the file's publishing project", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = require("org.utils").realpath(dir)
    utils.writefile(dir .. "/page.org", { "* Page" })
    config.setup({
      export = {
        publish = {
          projects = {
            site = { base_directory = dir, base_extension = "org", html_extension = "htm", publishing_directory = dir },
          },
        },
      },
    })
    vim.cmd("edit! " .. dir .. "/page.org")
    local prompts, restore = answer({ "", "", "", "", false })
    protocol.create_for_org()
    restore()
    eq(dir, prompts[2][2])
    eq("Extension to strip from published URLs (htm): ", prompts[3][1])
    eq("Extension of editable files (.org): ", prompts[4][1])
    vim.cmd("enew")
    local msgs = {}
    local orig = utils.notify
    utils.notify = function(m)
      msgs[#msgs + 1] = m
    end
    eq(nil, protocol.create_for_org())
    utils.notify = orig
    eq("Not in an Org project.  Did you mean `:Org protocol_create`?", msgs[1])
  end)
end)
