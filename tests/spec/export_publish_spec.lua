local publish = require("org.export.publish")
local config = require("org.config")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local fixtures = root .. "/fixtures/export/publish"

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function copy_tree(src, dst)
  vim.fn.mkdir(dst, "p")
  for name, t in vim.fs.dir(src) do
    if t == "directory" then
      copy_tree(src .. "/" .. name, dst .. "/" .. name)
    else
      vim.uv.fs_copyfile(src .. "/" .. name, dst .. "/" .. name)
    end
  end
end

--- A copy of the fixture project and the project configuration used to
--- produce the Emacs outputs under fixtures/export/publish/expected.
local function setup()
  local dir = vim.fn.tempname()
  copy_tree(fixtures .. "/src", dir .. "/src")
  local out = dir .. "/out"
  config.opts.babel.evaluate_on_export = false
  config.opts.export.publish = {
    timestamp_directory = out .. "/ts/",
    list_skipped_files = false,
    projects = {
      {
        name = "site-list",
        base_directory = dir .. "/src",
        publishing_directory = out .. "/list",
        recursive = true,
        exclude = "about",
        publishing_function = "org",
        auto_sitemap = true,
        sitemap_filename = "map.org",
        sitemap_style = "list",
      },
      {
        name = "site-org",
        base_directory = dir .. "/src",
        publishing_directory = out .. "/html",
        recursive = true,
        publishing_function = "html",
        auto_sitemap = true,
        sitemap_title = "My Site",
        makeindex = true,
      },
      {
        name = "site-static",
        base_directory = dir .. "/src",
        base_extension = "png",
        publishing_directory = out .. "/html",
        recursive = true,
        publishing_function = "attachment",
      },
      { name = "site", components = { "site-org", "site-static" } },
    },
  }
  return dir, out
end

local function drop_volatile(s)
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    if not line:match("^# Created") and not line:match("^#%+author:") then
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

describe("export publish (ox-publish)", function()
  it("publishes all projects like Emacs: sitemaps, index, attachments, cross-file links", function()
    local dir, out = setup()
    publish.publish_all(true)
    -- site maps and index are byte-identical to Emacs
    eq(read(fixtures .. "/expected/sitemap.org"), read(dir .. "/src/sitemap.org"))
    eq(read(fixtures .. "/expected/map.org"), read(dir .. "/src/map.org"))
    eq(read(fixtures .. "/expected/theindex.inc"), read(dir .. "/src/theindex.inc"))
    eq('#+TITLE: Index\n\n#+INCLUDE: "theindex.inc"\n\n', read(dir .. "/src/theindex.org"))
    -- org publishing function
    eq(drop_volatile(read(fixtures .. "/expected/list-index.org")), drop_volatile(read(out .. "/list/index.org")))
    ok(vim.fn.filereadable(out .. "/list/sub/page.org") == 1)
    ok(vim.fn.filereadable(out .. "/list/about.org") == 0, "excluded file was published")
    -- html files, attachments and the index page
    for _, f in ipairs({ "index.html", "about.html", "sub/page.html", "sitemap.html", "theindex.html", "img/logo.png" }) do
      ok(vim.fn.filereadable(out .. "/html/" .. f) == 1, "missing " .. f)
    end
    eq("PNGDATA\n", read(out .. "/html/img/logo.png"))
    -- a link to a headline of another file uses the id of that headline
    local index = read(out .. "/html/index.html")
    local ref = index:match('href="sub/page%.html#(org%x+)"')
    ok(ref, index)
    ok(read(out .. "/html/sub/page.html"):find('<h2 id="' .. ref .. '">', 1, true))
    ok(read(out .. "/html/theindex.html"):find('href="sub/page.html#' .. ref .. '"', 1, true))
  end)

  it("skips unmodified files and republishes changed ones", function()
    local dir, out = setup()
    publish.publish_project("site-org")
    local html = out .. "/html/about.html"
    vim.uv.fs_unlink(html)
    publish.publish_project("site-org")
    ok(vim.fn.filereadable(html) == 0, "unmodified file was republished")
    -- touch the source: newer than the timestamp
    local src = dir .. "/src/about.org"
    local t = os.time() + 10
    vim.uv.fs_utime(src, t, t)
    publish.publish_project("site-org")
    ok(vim.fn.filereadable(html) == 1)
    -- force publishes everything
    vim.uv.fs_unlink(out .. "/html/index.html")
    publish.publish_project("site-org", true)
    ok(vim.fn.filereadable(out .. "/html/index.html") == 1)
  end)

  it("finds projects of files and publishes the current file", function()
    local dir, out = setup()
    local p = publish.get_project_from_filename(dir .. "/src/sub/page.org")
    eq("site-list", p[1])
    eq("site-org", publish.get_project_from_filename(dir .. "/src/about.org")[1])
    eq("site", publish.get_project_from_filename(dir .. "/src/img/logo.png", true)[1])
    eq("site-static", publish.get_project_from_filename(dir .. "/src/img/logo.png")[1])
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/src/about.org"))
    publish.publish_current_file(true)
    ok(vim.fn.filereadable(out .. "/html/about.html") == 1)
    vim.cmd("bwipeout!")
  end)

  it("expands meta projects and lists base files", function()
    local dir = setup()
    local names = {}
    for _, p in ipairs(publish.expand_projects({ { "site", { components = { "site-org", "site-static" } } } })) do
      names[#names + 1] = p[1]
    end
    eq({ "site-org", "site-static" }, names)
    local files = publish.get_base_files({ "x", { base_directory = dir .. "/src" } })
    local rel = {}
    for _, f in ipairs(files) do
      rel[#rel + 1] = vim.fn.fnamemodify(f, ":t")
    end
    eq({ "about.org", "index.org" }, rel)
  end)

  it("resolves links to other files without publishing like Emacs", function()
    local dir = setup()
    vim.fn.writefile({ "* Head", ":PROPERTIES:", ":CUSTOM_ID: hd", ":END:", "* Plain" }, dir .. "/other.org")
    publish.reset_cache()
    local info = { input_file = dir .. "/main.org" }
    eq("hd", publish.resolve_external_link("*Head", "other.org", info))
    eq("x", publish.resolve_external_link("#x", "other.org", info))
    eq("MissingReference", publish.resolve_external_link("*Plain", "other.org", info))
    eq("sub/a.org", publish.file_relative_name(dir .. "/src/sub/a.org", { base_directory = dir .. "/src" }))
    eq("rel.org", publish.file_relative_name("rel.org", { base_directory = dir .. "/src" }))
  end)

  it("builds list and tree site maps with custom sorting", function()
    local dir = setup()
    local project = { "t", { base_directory = dir .. "/src", recursive = true, sitemap_sort_files = "anti-chronologically", sitemap_style = "list" } }
    publish.initialize_cache("t")
    publish.sitemap(project, "sm.org")
    local s = read(dir .. "/src/sm.org")
    -- A Page has a 2026-01-02 date; the others use their file modification time
    ok(s:match("^#%+TITLE: Sitemap for project t\n\n"), s)
    ok(s:find("- [[file:sub/page.org][A Page]]", 1, true), s)
    eq("- a\n  - [[file:b.org][B]]", publish.list_to_org({ "unordered", { "a", { "unordered", { "[[file:b.org][B]]" } } } }))
  end)
end)
