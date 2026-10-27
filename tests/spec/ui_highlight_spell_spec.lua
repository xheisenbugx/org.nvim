-- Spell checking with the parser highlighter: the words `]s` stops on
-- (with a dictionary of one word, every word it checks) are those Emacs's
-- flyspell checks (org-mode-flyspell-verify: org-element's elements and
-- objects), and what the screen leaves out is skipped.

local spell_dir = vim.fn.tempname()
vim.fn.mkdir(spell_dir .. "/spell", "p")
vim.fn.writefile({ "zzzzq" }, spell_dir .. "/words")
vim.cmd("silent mkspell! " .. spell_dir .. "/spell/zz " .. spell_dir .. "/words")
vim.opt.runtimepath:append(spell_dir)

--- The words `]s` stops on in `lines`: "line:col" -> word.
local function words(lines)
  local got = {}
  local ok, err = pcall(function()
    local buf = org_buffer(lines, { 1, 0 })
    vim.wo.spell = true
    vim.wo.foldenable = false
    vim.bo[buf].spelllang = "zz"
    vim.bo[buf].spellcapcheck = ""
    vim.bo[buf].spelloptions = ""
    local wrapscan = vim.o.wrapscan
    vim.o.wrapscan = false
    local function add()
      local p = vim.api.nvim_win_get_cursor(0)
      local key = p[1] .. ":" .. p[2]
      if got[key] then
        return false
      end
      got[key] = vim.fn.spellbadword()[1]
      return true
    end
    if vim.fn.spellbadword()[1] ~= "" then
      add()
    end
    while pcall(vim.cmd, "silent normal! ]s") and add() do
    end
    vim.o.wrapscan = wrapscan
  end)
  assert(ok, err)
  return got
end

describe("parser highlighter spelling", function()
  with_config({ ui = {} })

  --- The words checked on line 1 of `lines` (in order).
  local function checked(lines)
    local got = words(lines)
    local out = {}
    for k, w in pairs(got) do
      local l, c = k:match("^(%d+):(%d+)$")
      if tonumber(l) == 1 then
        out[#out + 1] = { tonumber(c), w }
      end
    end
    table.sort(out, function(a, b)
      return a[1] < b[1]
    end)
    return table.concat(
      vim.tbl_map(function(x)
        return x[2]
      end, out),
      " "
    )
  end

  it("]s skips what the screen leaves out (the marks of the decoration provider)", function()
    eq("see and", checked({ "see =verbatim= and ~code~ [[https://x.org]]" }))
  end)

  it("checks verbatim's text after its closing marker opened another", function()
    -- (font-lock draws ", the rest" in verbatim too)
    eq("a the rest", checked({ 'a =x = "y"=, the rest', "=z=" }))
  end)

  it("checks emphasis in table rows, not the rest of them", function()
    eq("bold", checked({ "| *bold* | plain | =v= |" }))
  end)

  it("checks the objects of a comment but its links", function()
    eq("see fn and", checked({ "# see [fn:1] and [[https://x.org]]" }))
  end)

  it("checks captions but their links and timestamps", function()
    eq("A table at", checked({ "#+CAPTION: A table at [2026-01-01 Thu] [[https://x.org]]" }))
  end)

  it("leaves keywords and block lines out, also in quote blocks", function()
    eq("", checked({ "#+NAME: some name" }))
    eq("", checked({ "#+end_quote" }))
    eq("", checked({ "#+1x: digits first" }))
    local buf_words = words({ "#+begin_quote", "#+keyword: in the quote", "text", "#+end_quote" })
    eq({ ["3:0"] = "text" }, buf_words)
  end)

  it("checks a comment block's body, as flyspell does", function()
    eq({ ["2:0"] = "a", ["2:2"] = "comment" }, words({ "#+begin_comment", "a comment", "#+end_comment" }))
  end)

  it("leaves a link over two lines out", function()
    eq({ ["1:0"] = "see", ["2:14"] = "and" }, words({ "see [[https://x.org][a long", "description]] and" }))
  end)

  it("leaves the emphasis in a list item's tag out, like the rest of the tag", function()
    eq("desc", checked({ "- *bold* tag :: desc" }))
  end)

  it("checks lines that aren't keywords to org-element", function()
    eq("key without colon", checked({ "#+key without colon" }))
    eq("a tab", checked({ "#\ta tab" }))
  end)
end)
