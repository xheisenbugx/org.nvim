-- Checks of the exercises of tutor/org/workflow.org, by exercise number
-- (see `org.tutor.Condition`). Exercises without an entry get no mark.

---@type org.tutor.Checks
return {
  -- the captured entry goes next to or under Inbox
  ["1.1"] = { min_headings = 2 },
  ["2.1"] = { heading = "Call the dentist", todo = "DONE" },
  ["2.2"] = { heading = "Water the plants", scheduled = true },
  ["3.1"] = { heading = "Write the report", clocked = true },
  ["3.2"] = {
    fn = function(ctx)
      for _, line in ipairs(ctx.lines) do
        if line:lower():match("^%s*#%+begin:%s+clocktable") then
          return true
        end
      end
      return false
    end,
  },
}
