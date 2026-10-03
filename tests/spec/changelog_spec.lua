local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local cl = dofile(root .. "/scripts/changelog.lua")

local URL = "https://example.invalid/org.nvim"

local function merge(n, branch, title, msgs)
  return {
    sha = string.rep("a", 40),
    subject = string.format("Merge pull request #%d from someone/%s", n, branch),
    body = title and (title .. "\n") or "",
    pr_messages = msgs,
  }
end

describe("changelog", function()
  describe("parse", function()
    it("splits type, scope, bang and description", function()
      eq({ type = "fix", scope = "ui", breaking = false, desc = "quit with q" }, cl.parse("fix(ui): quit with q"))
      eq({ type = "feat", breaking = true, desc = "require Neovim 0.11" }, cl.parse("feat!: require Neovim 0.11"))
      eq("ql,super-agenda", cl.parse("feat(ql,super-agenda): add views").scope)
      eq(nil, cl.parse("Add feature modules: structure, folding"))
      eq(nil, cl.parse("fix:missing space"))
    end)
  end)

  describe("classify", function()
    it("groups Conventional Commits types", function()
      eq("feat", cl.classify("feat(agenda): x").group)
      eq("fix", cl.classify("fix: x").group)
      eq("perf", cl.classify("perf: x").group)
      eq("docs", cl.classify("docs(readme): x").group)
      eq("refactor", cl.classify("refactor: x").group)
      for _, t in ipairs({ "test", "ci", "build", "chore", "style" }) do
        eq("chore", cl.classify(t .. ": x").group)
      end
    end)

    it("leaves release commits out", function()
      eq(nil, cl.classify("release: CHANGELOG for v1.3.0").group)
    end)

    it("guesses the type of other subjects from the branch or the words", function()
      local e = cl.classify("Close the parity gaps (round 4)", "feat/parity-round-4")
      eq({ "feat", "Close the parity gaps (round 4)" }, { e.group, e.desc })
      eq("fix", cl.classify("Something odd", "fix/odd").group)
      eq("feat", cl.classify("Core: config, date engine, parser").group)
      eq("docs", cl.classify("Add documentation (README, :h org.nvim), tutorial").group)
      eq("fix", cl.classify("Fix the parser").group)
    end)
  end)

  describe("entry", function()
    it("takes a merge commit's title and pull request number", function()
      local e = cl.entry(merge(12, "fix/table-rows", "fix(table): move rows"))
      eq({ 12, "fix", "table", "move rows" }, { e.pr, e.group, e.scope, e.desc })
    end)

    it("falls back to the pull request's commits when the title is the branch", function()
      local e = cl.entry(merge(23, "feat/emacs-parity-review", "Feat/emacs parity review", {
        "Merge pull request #20 from someone/fix/x\n\n",
        "feat(agenda): support holidays\n\n",
      }))
      eq({ "feat", "agenda", "support holidays" }, { e.group, e.scope, e.desc })
    end)

    it("marks a BREAKING CHANGE footer in the pull request's commits", function()
      local e = cl.entry(merge(89, "feat/nvim", "feat: require Neovim 0.11", {
        "feat: require Neovim 0.11\n\nDrop 0.10.\n\nBREAKING CHANGE: needs 0.11.",
      }))
      ok(e.breaking)
      ok(not cl.entry(merge(90, "fix/x", "fix: x", { "fix: x\n\nno break here" })).breaking)
    end)
  end)

  describe("render", function()
    it("bolds scopes, links pull requests and escapes key notation", function()
      local e = cl.classify("fix(mappings): give <C-c><C-r> to `<C-x>` only, see #36")
      e.pr = 57
      eq(
        "- **mappings:** Give \\<C-c>\\<C-r> to `<C-x>` only, see [#36]("
          .. URL
          .. "/pull/36) ([#57]("
          .. URL
          .. "/pull/57))",
        cl.render_entry(e, { url = URL })
      )
    end)

    it("doesn't capitalize an identifier", function()
      local e = cl.classify("fix: toggle_radio works")
      eq("- toggle_radio works", cl.render_entry(e, { url = URL }))
    end)

    it("puts breaking changes first and collapses chores", function()
      local entries = {}
      for _, s in ipairs({ "ci: run tests", "fix(ui): a fix", "feat(agenda): a feature", "feat!: drop 0.10" }) do
        entries[#entries + 1] = cl.classify(s)
      end
      local text = cl.render({
        { name = "Unreleased", prev = "v1.1.0", entries = {} },
        { name = "v1.1.0", date = "2026-10-02", prev = "v1.0.0", entries = entries },
        { name = "v1.0.0", date = "2026-10-01", entries = {} },
      }, { url = URL })
      local lines = vim.split(text, "\n")
      local function at(s)
        for i, l in ipairs(lines) do
          if l == s then
            return i
          end
        end
      end
      local v = at("## [v1.1.0] - 2026-10-02")
      ok(v and at("## [Unreleased]") < v)
      ok(at("### ⚠ Breaking changes") > v)
      ok(at("- Drop 0.10") > at("### ⚠ Breaking changes"))
      ok(at("### Features") > at("- Drop 0.10"))
      ok(at("### Fixes") > at("- **agenda:** A feature"))
      ok(at("<details><summary>Tests, CI and chores (1)</summary>") > at("- **ui:** A fix"))
      ok(at("- **ci:** Run tests"))
      ok(at("[v1.1.0]: " .. URL .. "/compare/v1.0.0...v1.1.0"))
      ok(at("[v1.0.0]: " .. URL .. "/releases/tag/v1.0.0"))
      ok(at("[Unreleased]: " .. URL .. "/compare/v1.1.0...dev"))
      -- the release notes: a version's entries without its heading
      local notes = cl.section(text, "v1.1.0")
      ok(notes:match("^### ⚠ Breaking changes"))
      ok(notes:match("</details>\n$"))
      ok(not notes:match("v1.0.0"))
      eq(nil, cl.section(text, "v9.9.9"))
    end)
  end)
end)
