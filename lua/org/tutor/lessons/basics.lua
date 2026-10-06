-- Checks of the exercises of tutor/org/basics.org, by exercise number
-- (see `org.tutor.Condition`). Exercises without an entry get no mark.

---@type org.tutor.Checks
return {
  ["1.2"] = { heading = "Pears", parent = "Fruit" },
  ["1.3"] = {
    { heading = "Carrot", parent = "Vegetables" },
    { heading = "Spoon", parent = "Drawer", depth = 2 },
  },
  ["1.4"] = { children = { "Monday", "Tuesday", "Wednesday" } },
  ["2.1"] = { heading = "Buy milk", todo = "DONE" },
  ["2.2"] = { heading = "Write a letter", todo = "TODO" },
  ["2.3"] = { heading = "Pay rent", priority = "A" },
  ["3.1"] = { heading = "Prepare slides", tags = { "work" } },
  ["4.1"] = { heading = "Water the plants", scheduled = true },
  ["4.2"] = { heading = "File the tax return", deadline = true },
  ["5.1"] = { item = "Butter" },
  ["5.2"] = { checked = "Eggs" },
  ["6.1"] = { table_aligned = true },
  ["6.2"] = { table_row = "Kiwi", table_aligned = true },
  ["7.1"] = { contains = "[[*Treasure chest]" },
}
