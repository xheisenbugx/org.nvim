-- Caches keyed by buffer changedtick (or scoped to one operation) must
-- never hand out stale results after an edit.

describe("babel block cache", function()
  local babel = require("org.babel")
  local config = require("org.config")
  local evaluate
  before_each(function()
    evaluate = babel.evaluate
    config.opts.babel.confirm_evaluate = false
    -- each block evaluates to its first body line, synchronously
    babel.evaluate = function(_, src, _, _, cb)
      local v = src.body[1]
      if cb then
        return cb(v, {})
      end
      return v, {}
    end
  end)
  after_each(function()
    babel.evaluate = evaluate
    config.opts.babel.confirm_evaluate = true
  end)

  it("re-parses at_block after an edit", function()
    local buf = org_buffer({ "#+begin_src sh", "echo one", "#+end_src" }, { 2, 0 })
    eq({ "echo one" }, babel.at_block(buf, 2).body)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "echo two" })
    eq({ "echo two" }, babel.at_block(buf, 2).body)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "", "" })
    eq(nil, babel.at_block(buf, 2))
    eq(3, babel.at_block(buf, 4).start)
  end)

  it("hands out copies, so callers can't corrupt the cache", function()
    local buf = org_buffer({ "#+begin_src sh", "echo one", "#+end_src" }, { 2, 0 })
    local b = babel.at_block(buf, 2)
    b.body[1] = "changed"
    b.start = 99
    eq({ "echo one" }, babel.at_block(buf, 2).body)
    eq(1, babel.at_block(buf, 2).start)
  end)

  it("inserts every result of execute_buffer at the right block", function()
    local buf = org_buffer({
      "#+begin_src sh",
      "a",
      "#+end_src",
      "",
      "#+begin_src sh",
      "b",
      "#+end_src",
      "",
      "#+begin_src sh",
      "c",
      "#+end_src",
    })
    babel.execute_buffer({ bufnr = buf, skip_confirm = true, sync = true })
    local expected = {
      "#+begin_src sh",
      "a",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": a",
      "",
      "#+begin_src sh",
      "b",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": b",
      "",
      "#+begin_src sh",
      "c",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": c",
    }
    eq(expected, buf_lines(buf))
    -- a second run replaces the results in place
    babel.execute_buffer({ bufnr = buf, skip_confirm = true, sync = true })
    eq(expected, buf_lines(buf))
  end)
end)
