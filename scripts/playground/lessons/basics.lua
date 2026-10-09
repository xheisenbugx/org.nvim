-- What the playground recording of tutor/org/basics.org does, exercise by
-- exercise (see scripts/playground/record.lua for the step format).
return {
  { id = "intro", title = "Welcome", hold = 2.5 },
  {
    id = "1.1",
    steps = {
      { at = "Kitchen" },
      { key = "{{org.cycle}}" },
      { key = "{{org.cycle}}" },
      { key = "{{org.cycle}}" },
      { key = "{{org.global_cycle}}" },
      { key = "{{org.global_cycle}}" },
      { key = "{{org.global_cycle}}" },
    },
  },
  {
    id = "1.2",
    steps = {
      { at = "Apples", col = "Apples" },
      { key = "{{org.meta_return}}" },
      { type = "Pears" },
      { key = "<Esc>" },
    },
  },
  {
    id = "1.3",
    steps = {
      { at = "Carrot" },
      { key = "{{org.demote_heading}}" },
      { at = "Spoon" },
      { key = "{{org.promote_heading}}" },
    },
  },
  { id = "1.4", steps = { { at = "Tuesday" }, { key = "{{org.meta_down}}" } } },
  { id = "2.1", steps = { { at = "Buy milk" }, { key = "{{org.todo_next}}" } } },
  { id = "2.2", steps = { { at = "Write a letter" }, { key = "{{org.todo_next}}" } } },
  { id = "2.3", steps = { { at = "Pay rent" }, { key = "{{org.priority}}" }, { key = "A" } } },
  {
    id = "3.1",
    steps = { { at = "Prepare slides" }, { key = "{{org.set_tags}}" }, { type = "work" }, { key = "<CR>" } },
  },
  { id = "4.1", steps = { { at = "Water the plants" }, { key = "{{org.schedule}}" }, { key = "<CR>" } } },
  {
    id = "4.2",
    steps = { { at = "File the tax return" }, { key = "{{org.deadline}}" }, { key = "<CR>" } },
  },
  {
    id = "5.1",
    steps = {
      { at = "- Bread", col = "Bread" },
      { key = "{{org.meta_return}}" },
      { type = "Butter" },
      { key = "<Esc>" },
    },
  },
  { id = "5.2", steps = { { at = "- [ ] Eggs", col = "Eggs" }, { key = "{{org.context_action}}" } } },
  { id = "6.1", steps = { { at = "| Apple", col = "Apple" }, { key = "{{org.context_action}}" } } },
  {
    id = "6.2",
    steps = {
      { at = "| Lemon", col = "Lemon" },
      { key = "A" },
      { key = "{{org_insert.insert_tab}}" },
      { type = "Kiwi" },
      { key = "{{org_insert.insert_tab}}" },
      { type = "5" },
      { key = "<Esc>" },
    },
  },
  {
    id = "7.1",
    steps = {
      { at = "Map:" },
      { key = "$" },
      { key = "{{org.insert_link}}" },
      { type = "*Treasure chest" },
      { key = "<CR>" },
      { type = "the treasure" },
      { key = "<CR>" },
      { key = "<Esc>" },
    },
  },
  { id = "7.2", steps = { { at = "Map:", col = "[[", whole = true }, { key = "{{org.open_at_point}}" } } },
}
