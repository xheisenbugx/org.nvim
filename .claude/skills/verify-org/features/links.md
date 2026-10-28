---
area: links
recipe: scripts/verify/recipes/links.lua
keys: org.open_at_point, org.store_link, org.insert_link, org.insert_last_stored_link, org.toggle_link_display, org.next_link, org.prev_link, global.store_link
modules: lua/org/links.lua, lua/org/links
specs: tests/spec/links_spec.lua, tests/spec/links_follow_spec.lua, tests/spec/links_emacs_spec.lua, tests/spec/links_parity_spec.lua, tests/spec/links_external_types_spec.lua
doc: org-links, org-insert-link
emacs: ol.el, org.el (org-open-at-point, org-insert-link)
---

# Links

Write a link to a heading, a file or a URL, follow it from the text, and
store the place you are at to link to it later (org-store-link,
org-insert-link, org-open-at-point).

## How to get to it

Open an org file. `{{org.open_at_point}}` (`<CR>`, also `gx`,
`<leader>oo`) on a link follows it. `{{org.store_link}}` (`<leader>ols`)
stores a link to where the cursor is; `{{org.insert_link}}`
(`<leader>oli`) asks for a target and a description and writes
`[[target][description]]`; `{{org.insert_last_stored_link}}`
(`<leader>olL`) writes the last stored link. `{{global.store_link}}`
stores from any buffer.

## Driving it

| Step | Expected |
| --- | --- |
| `{{org.open_at_point}}` on `[[*Garden]]` | cursor on `* Garden`, same window |
| `{{org.open_at_point}}` on `[[file:other.org::*Kitchen][...]]` | `other.org` in a new split above, cursor on `* Kitchen` |
| `{{org.open_at_point}}` on `[[*Shed]]` (no such heading) | "No match - create this as a new heading?" `(Y)es, [N]o:` |
| `y` | `* Shed` added at the end of the file, cursor on it |
| `{{org.store_link}}` on a heading | "Stored: Garden" in the message area |
| `{{org.insert_last_stored_link}}` | `[[*Garden][Garden]]` and a new line |
| `{{org.insert_link}}` | "Insert link:" prompt (with a stored link: "Insert link (default ...):") |
| type the target, `<CR>` | "Description:" prompt, empty |
| type the description, `<CR>` | `[[target][description]]` at the cursor |

## Gotchas

- Links are concealed: the screen shows `See *Garden and the kitchen.`
  for `See [[*Garden]] and [[file:other.org::*Kitchen][the kitchen]].`
  A `screen` check finds the description (or the bare target), never the
  brackets; check the raw text with `buffer` / `line` / `file`.
- Put the cursor on the link with `at` and `col`: `at` searches the raw
  line, so `{ at = "See [[", col = "the kitchen" }` lands inside the
  second link even though the brackets are hidden.
- A heading link to the current file stays in the window; a `file:` (and
  `id:`) link opens in another window, splitting when there is only one
  (`links.frame_setup`). After it, the current buffer is the other file:
  `buffer` / `line` expectations look at it, not the file you came from.
- A stored link to the current file is inserted as its search option,
  `[[*Garden][Garden]]`, not `file:...::*Garden`.
  `{{org.insert_last_stored_link}}` adds a newline after it: the file
  gets an extra empty line.
- A link to a heading that doesn't exist asks to create it
  (`links.search_must_match_exact_headline = "query-to-create"`, the
  default): a confirm in the message area, mode `r?`. Answer it with a
  `key` step (`y` / `n`), or the scenario stalls there.
- The screen's trailing blanks are dropped: expect `"Insert link:"`, not
  `"Insert link: "`. While a prompt is open the mode is `c`.
- Inserting a link edits the buffer only; save (`cmd = "write"`) before
  an `expect.file`.
- `{{org.toggle_link_display}}` (`<leader>olt`) shows every link in full;
  `{{org.next_link}}` / `{{org.prev_link}}` move between links. Not in
  the recipe.
