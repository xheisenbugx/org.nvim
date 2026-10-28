-- Links (feature map: .claude/skills/verify-org/features/links.md).
local notes = {
  "* Index",
  "See [[*Garden]] and [[file:other.org::*Kitchen][the kitchen]].",
  "* Garden",
  "Plant the bulbs.",
}
local other = { "* Hall", "* Kitchen", "Fix the tap." }

return {
  {
    name = "an internal heading link lands on the heading",
    files = { ["index.org"] = notes },
    open = "index.org",
    steps = {
      { at = "See [[", col = "Garden" },
      { key = "{{org.open_at_point}}", expect = { line = "^%* Garden$", buffer = "Plant" } },
    },
  },
  {
    name = "a file link opens the other file on its heading",
    files = { ["index.org"] = notes, ["other.org"] = other },
    open = "index.org",
    steps = {
      { at = "See [[", col = "the kitchen" },
      { key = "{{org.open_at_point}}", expect = { buffer = "Fix the tap", line = "^%* Kitchen$" } },
    },
  },
  {
    name = "a stored link is inserted with its description",
    files = { ["index.org"] = notes },
    open = "index.org",
    steps = {
      { at = "* Garden" },
      { key = "{{org.store_link}}" },
      { at = "Plant the bulbs." },
      { key = "o<Esc>{{org.insert_last_stored_link}}" },
      { cmd = "write" },
      {
        expect = {
          file = { "index.org", lines = vim.list_extend(vim.list_extend({}, notes), { "[[*Garden][Garden]]", "" }) },
        },
      },
    },
  },
  {
    name = "insert link asks for the target and a description",
    files = { ["index.org"] = notes, ["other.org"] = other },
    open = "index.org",
    steps = {
      { at = "Plant the bulbs." },
      { key = "A <Esc>{{org.insert_link}}", expect = { screen = "Insert link:", mode = "c" } },
      { type = "file:other.org::*Hall" },
      { key = "<CR>", expect = { screen = "Description:" } },
      { type = "the hall" },
      { key = "<CR>" },
      { cmd = "write" },
      { expect = { file = { "index.org", "^Plant the bulbs%. %[%[file:other%.org::%*Hall%]%[the hall%]%]$" } } },
    },
  },
  {
    name = "a link to a missing heading offers to create it",
    files = { ["index.org"] = { "* Index", "Tidy [[*Shed]]." } },
    open = "index.org",
    steps = {
      { at = "Tidy", col = "Shed" },
      { key = "{{org.open_at_point}}", expect = { screen = "No match - create this as a new heading?" } },
      { key = "y", expect = { line = "^%* Shed$" } },
      { cmd = "write" },
      { expect = { file = { "index.org", lines = { "* Index", "Tidy [[*Shed]].", "* Shed" } } } },
    },
  },
}
