.PHONY: test snapshots lint format site media publish-media parity-fixtures changelog typecheck coverage fuzz

# A throwaway data and cache dir: tests never touch the real ID database, clock
# state, agenda index or other stdpath("data") and stdpath("cache") files,
# and parallel runs don't collide.
test:
	@d=$$(mktemp -d) && XDG_DATA_HOME=$$d XDG_CACHE_HOME=$$d/cache nvim --headless -u tests/minimal_init.lua -l tests/run.lua $(SPEC); \
	s=$$?; rm -rf $$d; exit $$s

# Rewrite the screen snapshot golden files (tests/fixtures/screen) from
# what is drawn now; review the changes before committing them.
snapshots:
	@ORG_UPDATE_SNAPSHOTS=1 $(MAKE) --no-print-directory test SPEC="$(or $(SPEC),tests/spec/screen_snapshot_spec.lua)"

# The specs with line coverage of lua/org (tests/coverage.lua): the report,
# lowest coverage first, goes to coverage/report.md (see CONTRIBUTING.md).
# The JIT is off and every line is counted, so it's several times slower:
# a spec file gets 30 minutes (ORG_TEST_TIMEOUT), and the specs' own time
# limits are off (under_coverage()).
coverage:
	@d=$$(mktemp -d) && rm -rf coverage && \
	ORG_COVERAGE_DIR=$(CURDIR)/coverage/counts XDG_DATA_HOME=$$d XDG_CACHE_HOME=$$d/cache \
	ORG_TEST_TIMEOUT=$${ORG_TEST_TIMEOUT:-1800} \
	nvim --headless -u tests/minimal_init.lua -l tests/run.lua $(SPEC); \
	s=$$?; rm -rf $$d; \
	nvim --clean --headless -l scripts/coverage_report.lua coverage/counts coverage || s=1; \
	exit $$s

# The fuzz specs with many more seeds: ORG_FUZZ_SCALE (40) times their
# defaults, or ORG_FUZZ_ITERATIONS each, from ORG_FUZZ_START (default: a
# random seed). See "Fuzzing" in CONTRIBUTING.md.
fuzz:
	@scale=$${ORG_FUZZ_SCALE:-40}; \
	start=$${ORG_FUZZ_START:-$$(( $$(od -An -N3 -tu4 /dev/urandom | tr -d ' ') + 1 ))}; \
	echo "fuzz: ORG_FUZZ_SCALE=$$scale ORG_FUZZ_ITERATIONS=$$ORG_FUZZ_ITERATIONS ORG_FUZZ_START=$$start"; \
	ORG_FUZZ_SCALE=$$scale ORG_FUZZ_START=$$start ORG_TEST_TIMEOUT=$${ORG_TEST_TIMEOUT:-3600} \
	$(MAKE) --no-print-directory test SPEC="$$(echo tests/spec/fuzz_*_spec.lua)"

# stylua, then the source rules of scripts/lint_sources.lua
lint:
	stylua --check lua plugin ftplugin syntax tests scripts/site
	nvim --headless --clean -l scripts/lint_sources.lua lua

# lua-language-server --check with .luarc.json: the diagnostics it gates on
# (warnings and errors) must stay at zero, and in the files listed in
# scripts/typecheck_strict.txt also the ones .luarc.json demotes to hints
# (scripts/typecheck.lua). Needs lua-language-server on PATH (CI pins the
# version) and nvim, for its runtime's type annotations ($VIMRUNTIME).
typecheck:
	@nvim --headless --clean -l scripts/typecheck.lua

# stylua sometimes needs a second pass to settle
format:
	stylua lua plugin ftplugin syntax tests scripts/site && stylua lua plugin ftplugin syntax tests scripts/site

# The documentation website (doc/org.txt, README.md, examples/*.org and the
# parity docs as HTML) in site/; see scripts/site/build.lua. Open
# site/index.html in a browser. A build empties site/ first, and refuses a
# directory no build made (scripts/site/outdir.lua).
site:
	@d=$$(mktemp -d) && XDG_DATA_HOME=$$d nvim --headless --clean -l scripts/site/build.lua site; \
	s=$$?; rm -rf $$d; exit $$s

# Re-record the README GIFs and screenshots (needs vhs and the
# BlexMono Nerd Font; see docs/media/README.md).
media:
	@for t in docs/media/tapes/*.tape; do \
	  case $$t in */common.tape) ;; *) vhs $$t & ;; esac; \
	done; wait

# Commit the recorded GIFs and screenshots in docs/media to the media
# branch, which the README links to, and push it. They are ignored here.
publish-media:
	@set -e; git fetch -q origin media; d=$$(mktemp -d); \
	git worktree add -q --detach $$d origin/media; \
	for f in docs/media/*.gif docs/media/*.png; do if [ -e "$$f" ]; then cp "$$f" $$d/; fi; done; \
	git -C $$d add -A; \
	if git -C $$d diff --cached --quiet; then echo "media: nothing new to publish"; \
	else git -C $$d commit -q -m "docs(media): update the README media" && git -C $$d push -q origin HEAD:media; fi; \
	git worktree remove --force $$d

# Regenerate the Emacs Org 9.8.10 outputs the *_parity specs compare with
# (needs Emacs; see scripts/emacs-parity/README.md). AREAS picks a subset.
parity-fixtures:
	scripts/emacs-parity/generate.sh $(AREAS)

# Regenerate CHANGELOG.md from the tags and merged pull requests. On a
# release/vX.Y.Z branch the commits after the latest tag go under vX.Y.Z;
# elsewhere pass VERSION=vX.Y.Z for that, or get an Unreleased section.
changelog:
	nvim --headless --clean -l scripts/changelog.lua $(if $(VERSION),--version $(VERSION))
