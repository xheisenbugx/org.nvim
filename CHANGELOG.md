# Changelog

All notable changes to org.nvim, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/). Each entry is a merged
pull request, by its [Conventional Commits](https://www.conventionalcommits.org/) title.

This file is generated from the git history by `make changelog`
(`scripts/changelog.lua`); edit the pull request titles, not this file.

## [v2.3.2] - 2026-10-07

### Fixes

- **fold:** End the TAB cycle when the cursor moves ([#208](https://github.com/xheisenbugx/org.nvim/pull/208))

## [v2.3.1] - 2026-10-06

### Fixes

- **fold:** Update folds whose levels an edit changed away from it ([#205](https://github.com/xheisenbugx/org.nvim/pull/205))
- **actions:** Show Vim's error for a failed key, not a Lua traceback ([#206](https://github.com/xheisenbugx/org.nvim/pull/206))

## [v2.3.0] - 2026-10-05

### Features

- Hugo export (ox-hugo port) and interactive :Org tutor ([#202](https://github.com/xheisenbugx/org.nvim/pull/202))

## [v2.2.0] - 2026-10-05

### Features

- Background agenda index, async babel and export, outline symbols, strict core types, module splits ([#194](https://github.com/xheisenbugx/org.nvim/pull/194))
- **textobjects:** Element, list item, table, link and timestamp objects; counts repeat edits ([#195](https://github.com/xheisenbugx/org.nvim/pull/195))
- **babel:** Show a running block's output live below it ([#196](https://github.com/xheisenbugx/org.nvim/pull/196))
- **commands:** Live 'inccommand' previews for :Org subcommands ([#197](https://github.com/xheisenbugx/org.nvim/pull/197))
- **syntax:** Highlight src blocks with tree-sitter when a parser exists ([#198](https://github.com/xheisenbugx/org.nvim/pull/198))
- **remote:** Run CLI and org-protocol requests in the running Neovim ([#199](https://github.com/xheisenbugx/org.nvim/pull/199))

### Performance

- **agenda:** Parse agenda files on worker threads in the background ([#200](https://github.com/xheisenbugx/org.nvim/pull/200))

## [v2.1.0] - 2026-10-04

### Features

- **keys:** Repeat org edits with . (dot-repeat) ([#184](https://github.com/xheisenbugx/org.nvim/pull/184))

### Fixes

- **keys:** Dot-repeat keeps the cursor when a fold is closed ([#185](https://github.com/xheisenbugx/org.nvim/pull/185))

## [v2.0.6] - 2026-10-04

### Fixes

- **site:** Render the manual's key and option lists as tables ([#182](https://github.com/xheisenbugx/org.nvim/pull/182))

## [v2.0.5] - 2026-10-04

### Fixes

- **agenda:** Every column view cell can be reached with the cursor ([#171](https://github.com/xheisenbugx/org.nvim/pull/171))

### Refactors

- **links:** Split links.lua into parse, search, open, shell, store, insert and commands ([#172](https://github.com/xheisenbugx/org.nvim/pull/172))
- **clock:** Split clock.lua into lua/org/clock/ by concern ([#176](https://github.com/xheisenbugx/org.nvim/pull/176))
- **capture:** Split capture.lua into templates, expand, target, place, session and buffer ([#175](https://github.com/xheisenbugx/org.nvim/pull/175))
- **fold:** Split fold.lua into lua/org/fold/ by concern ([#178](https://github.com/xheisenbugx/org.nvim/pull/178))
- **table:** Split table.lua into command parts ([#174](https://github.com/xheisenbugx/org.nvim/pull/174))
- **structure:** Split structure.lua into lua/org/structure/ parts ([#173](https://github.com/xheisenbugx/org.nvim/pull/173))

<details><summary>Tests, CI and chores (1)</summary>

- **chore(typecheck):** Strict nil and type checks for api/ and parser.lua ([#177](https://github.com/xheisenbugx/org.nvim/pull/177))

</details>

## [v2.0.4] - 2026-10-04

### Fixes

- **agenda:** r turns column view back on when view_columns_initially is set ([#165](https://github.com/xheisenbugx/org.nvim/pull/165))
- **agenda:** e on a DEADLINE or SCHEDULED column cell opens the date prompt ([#166](https://github.com/xheisenbugx/org.nvim/pull/166))
- **agenda:** Column view shows a parent's summary of its children ([#167](https://github.com/xheisenbugx/org.nvim/pull/167))
- **menu:** Don't show default keys when mappings.disable_all is set ([#168](https://github.com/xheisenbugx/org.nvim/pull/168))
- **agenda:** The tag filter prompt says Esc quits ([#169](https://github.com/xheisenbugx/org.nvim/pull/169))

<details><summary>Tests, CI and chores (1)</summary>

- **chore(changelog):** Don't capitalize a one-letter key at the start of a title ([bc37564](https://github.com/xheisenbugx/org.nvim/commit/bc37564eee0133c8fe060e65a446614c73ca9e2e))

</details>

## [v2.0.3] - 2026-10-03

### Fixes

- **fold:** The archived subtree message names the force-cycle key ([#156](https://github.com/xheisenbugx/org.nvim/pull/156))
- **fold:** VISIBILITY all leaves drawers open under nohidedrawers ([#157](https://github.com/xheisenbugx/org.nvim/pull/157))
- **export:** HTML export keeps going on a search link to a non-org file ([#158](https://github.com/xheisenbugx/org.nvim/pull/158))
- **agenda:** Column view shows values the way the column view does ([#160](https://github.com/xheisenbugx/org.nvim/pull/160))
- **agenda:** A custom command's settings set its column view format ([#162](https://github.com/xheisenbugx/org.nvim/pull/162))
- **tags:** The fast tag selection footer says Esc quits ([#161](https://github.com/xheisenbugx/org.nvim/pull/161))

### Documentation

- **examples:** The tutorial's ddg link encodes its search words ([#155](https://github.com/xheisenbugx/org.nvim/pull/155))

<details><summary>Tests, CI and chores (2)</summary>

- **ci:** Time the perf specs alone and split the Windows run over three runners ([#153](https://github.com/xheisenbugx/org.nvim/pull/153))
- **test(agenda):** The custom command column spec expects DEADLINE shown inactive ([#164](https://github.com/xheisenbugx/org.nvim/pull/164))

</details>

## [v2.0.2] - 2026-10-03

### Fixes

- **agenda:** . keeps the span and moves to today ([#140](https://github.com/xheisenbugx/org.nvim/pull/140))
- **timestamps:** A repeated insert right after a timestamp makes a range ([#144](https://github.com/xheisenbugx/org.nvim/pull/144))
- **links:** Store a link to a target at the start or end of a line ([#150](https://github.com/xheisenbugx/org.nvim/pull/150))
- **links:** A target inside a link's description isn't the link's target ([#145](https://github.com/xheisenbugx/org.nvim/pull/145))
- **columns:** A stores allowed values where Emacs does ([#148](https://github.com/xheisenbugx/org.nvim/pull/148))
- **ui:** Pickers are wide enough for their title and footer ([#142](https://github.com/xheisenbugx/org.nvim/pull/142))
- **capture:** Capture from Visual mode with the selection as %i ([#147](https://github.com/xheisenbugx/org.nvim/pull/147))
- **babel:** One-line message for a cached result ([#146](https://github.com/xheisenbugx/org.nvim/pull/146))
- **completion:** Custom IDs complete after [[# with omnifunc ([#149](https://github.com/xheisenbugx/org.nvim/pull/149))
- **core:** Keep typed-ahead keys when leaving Visual mode ([#143](https://github.com/xheisenbugx/org.nvim/pull/143))
- **export:** Multi-step PDF compiles no longer crash ([#141](https://github.com/xheisenbugx/org.nvim/pull/141))
- **fold:** C-c C-c on a #+ line keeps the folds, :edit applies #+STARTUP again ([#139](https://github.com/xheisenbugx/org.nvim/pull/139))

### Documentation

- **tutorial:** Make every exercise work as written ([#151](https://github.com/xheisenbugx/org.nvim/pull/151))

## [v2.0.1] - 2026-10-03

### Fixes

- **calendar:** Hint q/Esc to cancel, like the other menus ([#137](https://github.com/xheisenbugx/org.nvim/pull/137))

## [v2.0.0] - 2026-10-03

### ⚠ Breaking changes

- Public API, pickers, CLI JSON envelope, docs site, CI checks, perf budgets and module splits ([#135](https://github.com/xheisenbugx/org.nvim/pull/135))

## [v1.2.5] - 2026-10-02

### Fixes

- **ui:** Quit menus and views with q as well as Esc, unless q is taken ([#132](https://github.com/xheisenbugx/org.nvim/pull/132))
- **tests:** Stop two specs failing near a week or month end ([#134](https://github.com/xheisenbugx/org.nvim/pull/134))

## [v1.2.4] - 2026-10-02

### Fixes

- **agenda:** Don't add the file a TODO change edits to the buffer list ([#130](https://github.com/xheisenbugx/org.nvim/pull/130))

## [v1.2.3] - 2026-10-02

### Documentation

- **readme:** Check every claim against the code; fix(health): pandoc and PDF checks ([#127](https://github.com/xheisenbugx/org.nvim/pull/127))

## [v1.2.2] - 2026-10-02

### Fixes

- **ui:** Rendering sweep: folding, highlighting, concealing and display bugs ([#125](https://github.com/xheisenbugx/org.nvim/pull/125))

## [v1.2.1] - 2026-10-02

### Fixes

- **syntax:** Don't highlight headline stars as bold markup ([#120](https://github.com/xheisenbugx/org.nvim/pull/120))
- **syntax:** Keep highlighting on long paragraph lines (E363) ([#122](https://github.com/xheisenbugx/org.nvim/pull/122))
- **fold:** Keep a folded headline's highlighting ([#123](https://github.com/xheisenbugx/org.nvim/pull/123))

## [v1.2.0] - 2026-10-02

### Features

- Emacs parity fixtures, source lint, extmark positions, in-place agenda updates, caches, fuzzing, write hooks, faster startup ([#113](https://github.com/xheisenbugx/org.nvim/pull/113))

### Fixes

- **test:** Wait for async shell links to finish before checking output ([#116](https://github.com/xheisenbugx/org.nvim/pull/116))

### Documentation

- Move the README media to the media branch ([#115](https://github.com/xheisenbugx/org.nvim/pull/115))

<details><summary>Tests, CI and chores (1)</summary>

- **ci:** Run spec files in parallel worker processes ([#114](https://github.com/xheisenbugx/org.nvim/pull/114))

</details>

## [v1.1.0] - 2026-10-01

### Features

- **notifications:** Windows toast notifications through powershell.exe ([#107](https://github.com/xheisenbugx/org.nvim/pull/107))
- Windows support: the specs pass on Windows, and the fixes that took ([#106](https://github.com/xheisenbugx/org.nvim/pull/106))

### Fixes

- Treat Windows drive and UNC paths as absolute, and find home without $HOME ([#108](https://github.com/xheisenbugx/org.nvim/pull/108))
- Write files with LF line endings on Windows too ([#109](https://github.com/xheisenbugx/org.nvim/pull/109))
- Plugin-wide review — security, data-loss, parity and performance fixes ([#110](https://github.com/xheisenbugx/org.nvim/pull/110))

## [v1.0.1] - 2026-10-01

### Documentation

- Drop the mentions of the gcal extension ([#98](https://github.com/xheisenbugx/org.nvim/pull/98))
- License org.nvim under MIT ([#99](https://github.com/xheisenbugx/org.nvim/pull/99))
- Mark each extension as stable or experimental ([#103](https://github.com/xheisenbugx/org.nvim/pull/103))

<details><summary>Tests, CI and chores (4)</summary>

- **chore:** Add issue forms and a pull request template ([#100](https://github.com/xheisenbugx/org.nvim/pull/100))
- **chore:** Group the release notes by kind of change ([#101](https://github.com/xheisenbugx/org.nvim/pull/101))
- **ci:** Check formatting with stylua 2.5.2 ([#102](https://github.com/xheisenbugx/org.nvim/pull/102))
- **test(sidebar):** Freeze the clock in the pomodoro phase spec ([#105](https://github.com/xheisenbugx/org.nvim/pull/105))

</details>

## [v1.0.0] - 2026-10-01

### ⚠ Breaking changes

- Require Neovim 0.11 ([#89](https://github.com/xheisenbugx/org.nvim/pull/89))

### Features

- Core: config, date engine, parser, edit primitives, actions, mappings, test runner ([e004c1a](https://github.com/xheisenbugx/org.nvim/commit/e004c1a6cc384df67ac83841ea23d2d390c0403a))
- Add feature modules: structure, folding, lists, TODO/clock/dates, agenda, capture/links/refile/archive, tables/babel/export, syntax, completion ([8c7dd7f](https://github.com/xheisenbugx/org.nvim/commit/8c7dd7fddcf37ced5296603ff4189b18bd6d7777))
- **mappings:** Promote/demote headings with Alt+Left/Right ([#2](https://github.com/xheisenbugx/org.nvim/pull/2))
- **mappings:** Emacs Org keybindings (C-c C-t, C-RET, C-c C-x …) ([#5](https://github.com/xheisenbugx/org.nvim/pull/5))
- **table:** Emacs-compatible spreadsheet formulas ([#8](https://github.com/xheisenbugx/org.nvim/pull/8))
- Close Emacs Org 9.8 parity gaps across tables, structure, TODO/clock, agenda and babel/export ([#13](https://github.com/xheisenbugx/org.nvim/pull/13))
- **babel:** Sessions, evaluating :var references and Emacs parity ([#16](https://github.com/xheisenbugx/org.nvim/pull/16))
- **clock:** Emacs parity for clocking, clock tables and resolving ([#17](https://github.com/xheisenbugx/org.nvim/pull/17))
- Emacs Org 9.8 parity review: bugs, Emacs defaults, missing features, documented gaps ([#19](https://github.com/xheisenbugx/org.nvim/pull/19))
- **agenda:** Support %%(org-calendar-holiday) with Emacs's holiday lists ([#23](https://github.com/xheisenbugx/org.nvim/pull/23))
- **health:** Check that the terminal can send the keys org maps ([#24](https://github.com/xheisenbugx/org.nvim/pull/24))
- **health:** Check kitty, WezTerm and Alacritty keys too ([#25](https://github.com/xheisenbugx/org.nvim/pull/25))
- **ui:** Inline image and LaTeX previews (vim.ui.img, with snacks/image.nvim fallback) ([#29](https://github.com/xheisenbugx/org.nvim/pull/29))
- **ui:** Bring image and LaTeX previews to Emacs parity ([#30](https://github.com/xheisenbugx/org.nvim/pull/30))
- Group the g? keymap help by topic ([#39](https://github.com/xheisenbugx/org.nvim/pull/39))
- **agenda:** Evaluate side-effect-free Elisp in diary sexps ([#42](https://github.com/xheisenbugx/org.nvim/pull/42))
- **babel:** Honor :async on session blocks like Emacs ([#43](https://github.com/xheisenbugx/org.nvim/pull/43))
- **calendar:** Redesign the date picker ([#44](https://github.com/xheisenbugx/org.nvim/pull/44))
- Close the Emacs Org parity roadmap gaps ([#45](https://github.com/xheisenbugx/org.nvim/pull/45))
- Close the roadmap and org-differences parity gaps (round 4) ([#47](https://github.com/xheisenbugx/org.nvim/pull/47))
- Measured Emacs Org 9.8.10 parity and the missing features (round 5) ([#72](https://github.com/xheisenbugx/org.nvim/pull/72))
- **ui:** Floating choice lists and clearer key menus ([#73](https://github.com/xheisenbugx/org.nvim/pull/73))
- **extensions:** Load optional built-in extensions from setup ([#66](https://github.com/xheisenbugx/org.nvim/pull/66))
- **roam:** Add an optional org-roam extension ([#71](https://github.com/xheisenbugx/org.nvim/pull/71))
- **present:** Slideshows of org buffers, like org-present ([#68](https://github.com/xheisenbugx/org.nvim/pull/68))
- **ql, super-agenda:** Add org-ql and org-super-agenda extensions ([#69](https://github.com/xheisenbugx/org.nvim/pull/69))
- **extensions:** 16 opt-in extensions beyond Emacs parity ([#82](https://github.com/xheisenbugx/org.nvim/pull/82))
- **version:** Take the release from the latest git tag ([#91](https://github.com/xheisenbugx/org.nvim/pull/91))

### Fixes

- **syntax:** Show only the description of links with one ([#1](https://github.com/xheisenbugx/org.nvim/pull/1))
- **utils:** Load buffers despite existing swap files ([#3](https://github.com/xheisenbugx/org.nvim/pull/3))
- **ui:** Draw decorations at redraw time to stop icon flicker ([#6](https://github.com/xheisenbugx/org.nvim/pull/6))
- **ui:** Quit menus with Esc so q can be a menu key ([#7](https://github.com/xheisenbugx/org.nvim/pull/7))
- **priority:** Don't scroll when a key removes the priority ([#10](https://github.com/xheisenbugx/org.nvim/pull/10))
- **table:** Map \<M-Up>/\<M-Down> to move rows ([#12](https://github.com/xheisenbugx/org.nvim/pull/12))
- **lists:** Normal-mode M-RET at column 0 of an item adds the item after it ([#21](https://github.com/xheisenbugx/org.nvim/pull/21))
- **ui:** Indent mode draws bullets and hidden stars over the stars ([#22](https://github.com/xheisenbugx/org.nvim/pull/22))
- **ui:** Draw snacks/image.nvim previews at the link, not after it ([#31](https://github.com/xheisenbugx/org.nvim/pull/31))
- Address review findings on [#36](https://github.com/xheisenbugx/org.nvim/pull/36) ([#37](https://github.com/xheisenbugx/org.nvim/pull/37))
- Preserve Org data and implement parity follow-ups ([#40](https://github.com/xheisenbugx/org.nvim/pull/40))
- **columns:** Keep cell faces off separators and hide fold bands ([#46](https://github.com/xheisenbugx/org.nvim/pull/46))
- **agenda:** Take the time of a \<%%(...)> stamp from the sexp ([#49](https://github.com/xheisenbugx/org.nvim/pull/49))
- **babel:** Only evaluate inline code that is a real object ([#60](https://github.com/xheisenbugx/org.nvim/pull/60))
- **table:** Add Calc floats in decimal and round times of day ([#64](https://github.com/xheisenbugx/org.nvim/pull/64))
- **mappings:** Don't fall back to the key after removing a date or toggling off ([#63](https://github.com/xheisenbugx/org.nvim/pull/63))
- **mappings:** Move todo_select to \<prefix>S so it is no prefix of the table keys ([#62](https://github.com/xheisenbugx/org.nvim/pull/62))
- **agenda:** Skip timestamps in comments and verbatim blocks ([#61](https://github.com/xheisenbugx/org.nvim/pull/61))
- **table:** Named columns after a row reference and in formula order ([#59](https://github.com/xheisenbugx/org.nvim/pull/59))
- **structure:** Sort entries when the last child is followed by a blank line ([#51](https://github.com/xheisenbugx/org.nvim/pull/51))
- **export:** Print a target's list ordinal in ASCII link notes ([#58](https://github.com/xheisenbugx/org.nvim/pull/58))
- **entities:** First duplicate wins, show only one-character symbols ([#56](https://github.com/xheisenbugx/org.nvim/pull/56))
- **mappings:** Map insert_drawer in Visual mode ([#55](https://github.com/xheisenbugx/org.nvim/pull/55))
- **export:** Honour visible-only and root properties in subtree exports ([#54](https://github.com/xheisenbugx/org.nvim/pull/54))
- **capture:** Keep prompting after %^g on a heading line ([#53](https://github.com/xheisenbugx/org.nvim/pull/53))
- **mappings:** Give \<C-c>\<C-x>\<C-r> to toggle_radio_button only ([#57](https://github.com/xheisenbugx/org.nvim/pull/57))
- **keymaps:** Let agenda keys wait for leader maps; free G in the agenda ([#74](https://github.com/xheisenbugx/org.nvim/pull/74))
- **notifications:** Send each reminder once, from one Neovim ([#79](https://github.com/xheisenbugx/org.nvim/pull/79))
- **roam:** Insert-mode links, backlinks window navigation and faster lookups ([#81](https://github.com/xheisenbugx/org.nvim/pull/81))
- **table:** Round exact ties to even in formula formats ([#93](https://github.com/xheisenbugx/org.nvim/pull/93))
- **special:** Keep the edit buffer when its source lines were deleted ([#92](https://github.com/xheisenbugx/org.nvim/pull/92))
- Hash strings with NUL bytes when sha256() rejects them ([#90](https://github.com/xheisenbugx/org.nvim/pull/90))
- **babel:** Run C# programs with DOTNET_ROOT of the SDK that built them ([#88](https://github.com/xheisenbugx/org.nvim/pull/88))
- **date:** Make local time follow a TZ changed at runtime on glibc ([#85](https://github.com/xheisenbugx/org.nvim/pull/85))

### Performance

- Keep editing fast in large Org files ([#48](https://github.com/xheisenbugx/org.nvim/pull/48))
- **agenda:** Cache hot paths of multi-file views ([#95](https://github.com/xheisenbugx/org.nvim/pull/95))

### Documentation

- Add documentation (README, :h org.nvim), tutorial, health check refinements ([6476d3b](https://github.com/xheisenbugx/org.nvim/commit/6476d3b3c3b4ef77e0b5cc8a7bfca661381908b8))
- Use real repository name in install snippets ([095a2fb](https://github.com/xheisenbugx/org.nvim/commit/095a2fbb2772357a21870c77140295cf505dac4f))
- Rename repository to org.nvim ([030f5e0](https://github.com/xheisenbugx/org.nvim/commit/030f5e0d8e4e9d6b4f1bc3563f291847b1d5f07c))
- Refresh README, add CONTRIBUTING guide and doc quick start ([#4](https://github.com/xheisenbugx/org.nvim/pull/4))
- **examples:** Expand the tutorial into a section per feature ([#9](https://github.com/xheisenbugx/org.nvim/pull/9))
- Note tmux extended-keys requirement for \<S-CR> ([#14](https://github.com/xheisenbugx/org.nvim/pull/14))
- LuaLS types for setup() options + fixes for bugs they surfaced ([#15](https://github.com/xheisenbugx/org.nvim/pull/15))
- **readme:** Add Ko-fi link ([#26](https://github.com/xheisenbugx/org.nvim/pull/26))
- **readme:** Show every feature with GIFs and screenshots ([#27](https://github.com/xheisenbugx/org.nvim/pull/27))
- **readme:** Add demos for lists, table editing and more ([#28](https://github.com/xheisenbugx/org.nvim/pull/28))
- Explain where image previews work (tmux, Neovim version, terminals) ([#32](https://github.com/xheisenbugx/org.nvim/pull/32))
- **readme:** Explain why org.nvim exists next to nvim-orgmode ([#33](https://github.com/xheisenbugx/org.nvim/pull/33))
- **readme:** Add demos for heading jumps, timers, reminders and more ([#34](https://github.com/xheisenbugx/org.nvim/pull/34))
- **readme:** Drop the "And the rest" screenshots ([#35](https://github.com/xheisenbugx/org.nvim/pull/35))
- Add a parity scorecard to the README ([#41](https://github.com/xheisenbugx/org.nvim/pull/41))
- **examples:** One hands-on org file per feature area ([#50](https://github.com/xheisenbugx/org.nvim/pull/50))
- Fix \<C-c>\<C-y> result format and clock timestamp keys ([#52](https://github.com/xheisenbugx/org.nvim/pull/52))
- Add AGENTS.md with guidance for coding agents ([#65](https://github.com/xheisenbugx/org.nvim/pull/65))
- Add project logo ([#67](https://github.com/xheisenbugx/org.nvim/pull/67))
- **readme:** Bring the README up to date ([#76](https://github.com/xheisenbugx/org.nvim/pull/76))
- Use the new app-icon logo ([#77](https://github.com/xheisenbugx/org.nvim/pull/77))
- **media:** Re-record the README GIFs and screenshots after the UI update ([#78](https://github.com/xheisenbugx/org.nvim/pull/78))

<details><summary>Tests, CI and chores (5)</summary>

- **ci:** Run tests on pull requests and release from release branches ([#83](https://github.com/xheisenbugx/org.nvim/pull/83))
- **test:** Fail a describe whose body errors without leaking it into later files ([#94](https://github.com/xheisenbugx/org.nvim/pull/94))
- **test(health):** Wait for :checkhealth to finish on Neovim 0.13 ([#86](https://github.com/xheisenbugx/org.nvim/pull/86))
- **test(ctags):** Record the fake ctags arguments with printf, not echo ([#84](https://github.com/xheisenbugx/org.nvim/pull/84))
- **style:** Format the code base with stylua and make lint pass ([#96](https://github.com/xheisenbugx/org.nvim/pull/96))

</details>

[v2.3.2]: https://github.com/xheisenbugx/org.nvim/compare/v2.3.1...v2.3.2
[v2.3.1]: https://github.com/xheisenbugx/org.nvim/compare/v2.3.0...v2.3.1
[v2.3.0]: https://github.com/xheisenbugx/org.nvim/compare/v2.2.0...v2.3.0
[v2.2.0]: https://github.com/xheisenbugx/org.nvim/compare/v2.1.0...v2.2.0
[v2.1.0]: https://github.com/xheisenbugx/org.nvim/compare/v2.0.6...v2.1.0
[v2.0.6]: https://github.com/xheisenbugx/org.nvim/compare/v2.0.5...v2.0.6
[v2.0.5]: https://github.com/xheisenbugx/org.nvim/compare/v2.0.4...v2.0.5
[v2.0.4]: https://github.com/xheisenbugx/org.nvim/compare/v2.0.3...v2.0.4
[v2.0.3]: https://github.com/xheisenbugx/org.nvim/compare/v2.0.2...v2.0.3
[v2.0.2]: https://github.com/xheisenbugx/org.nvim/compare/v2.0.1...v2.0.2
[v2.0.1]: https://github.com/xheisenbugx/org.nvim/compare/v2.0.0...v2.0.1
[v2.0.0]: https://github.com/xheisenbugx/org.nvim/compare/v1.2.5...v2.0.0
[v1.2.5]: https://github.com/xheisenbugx/org.nvim/compare/v1.2.4...v1.2.5
[v1.2.4]: https://github.com/xheisenbugx/org.nvim/compare/v1.2.3...v1.2.4
[v1.2.3]: https://github.com/xheisenbugx/org.nvim/compare/v1.2.2...v1.2.3
[v1.2.2]: https://github.com/xheisenbugx/org.nvim/compare/v1.2.1...v1.2.2
[v1.2.1]: https://github.com/xheisenbugx/org.nvim/compare/v1.2.0...v1.2.1
[v1.2.0]: https://github.com/xheisenbugx/org.nvim/compare/v1.1.0...v1.2.0
[v1.1.0]: https://github.com/xheisenbugx/org.nvim/compare/v1.0.1...v1.1.0
[v1.0.1]: https://github.com/xheisenbugx/org.nvim/compare/v1.0.0...v1.0.1
[v1.0.0]: https://github.com/xheisenbugx/org.nvim/releases/tag/v1.0.0
