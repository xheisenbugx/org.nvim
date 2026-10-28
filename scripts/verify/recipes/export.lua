-- Export (feature map: .claude/skills/verify-org/features/export.md).
-- Only the native back-ends (ASCII, HTML, Markdown): no pandoc or LaTeX.
-- The author is set in the file: it otherwise comes from the system's
-- user name, which differs between machines.
local notes = {
  "#+TITLE: Trip notes",
  "#+AUTHOR: Ada Lovelace",
  "#+OPTIONS: toc:nil",
  "* Packing",
  "Bring a *warm* coat.",
  "- passport",
  "- tickets",
  "* Budget",
  "About 300 euros.",
}

return {
  {
    name = "the dispatcher exports plain text to a file",
    files = { ["trip.org"] = notes },
    open = "trip.org",
    steps = {
      { key = "{{org.export}}", expect = { screen = { "Org Export", "Export to Plain Text" } } },
      { key = "t", expect = { screen = { "As ASCII buffer", "As ASCII file" } } },
      { key = "a", expect = { screen = "Exported to", no_screen = "Org Export" } },
      {
        expect = {
          file = {
            "trip.txt",
            lines = {
              "                             ______________",
              "",
              "                               TRIP NOTES",
              "",
              "                              Ada Lovelace",
              "                             ______________",
              "",
              "",
              "1 Packing",
              "=========",
              "",
              "  Bring a *warm* coat.",
              "  - passport",
              "  - tickets",
              "",
              "",
              "2 Budget",
              "========",
              "",
              "  About 300 euros.",
            },
          },
        },
      },
    },
  },
  {
    name = "the dispatcher exports an HTML file",
    files = { ["trip.org"] = notes },
    open = "trip.org",
    steps = {
      { key = "{{org.export}}h", expect = { screen = { "As HTML buffer", "As HTML file" } } },
      { key = "h", expect = { screen = "Exported to" } },
      { expect = { file = { "trip.html", "^<title>Trip notes</title>$" } } },
      {
        expect = { file = { "trip.html", '^<h2 id="[%w-]+"><span class="section%-number%-2">2%.</span> Budget</h2>$' } },
      },
      { expect = { file = { "trip.html", "^Bring a <b>warm</b> coat%.$" } } },
      { expect = { file = { "trip.html", "^<li>passport</li>$" } } },
      { expect = { file = { "trip.html", '^<p class="date">Created: 2026%-10%-12 Mon 09:00</p>$' } } },
    },
  },
  {
    name = "Org export md writes Markdown",
    files = { ["trip.org"] = notes },
    open = "trip.org",
    steps = {
      { cmd = "Org export md", expect = { screen = "Exported to" } },
      {
        expect = {
          file = {
            "trip.md",
            lines = {
              "",
              "",
              "# Packing",
              "",
              "Bring a **warm** coat.",
              "",
              "-   passport",
              "-   tickets",
              "",
              "",
              "# Budget",
              "",
              "About 300 euros.",
              "",
            },
          },
        },
      },
    },
  },
  {
    name = "the subtree toggle exports only the heading at the cursor",
    files = { ["trip.org"] = notes },
    open = "trip.org",
    steps = {
      { at = "* Budget" },
      { key = "{{org.export}}", expect = { screen = "Export scope", no_screen = "subtree" } },
      { key = "s", expect = { screen = "subtree" } },
      { key = "m", expect = { screen = { "To temporary buffer", "To file" } } },
      { key = "m", expect = { screen = "Exported to" } },
      { expect = { file = { "trip.md", lines = { "About 300 euros.", "" } } } },
    },
  },
}
