.PHONY: test lint format media publish-media parity-fixtures

# A throwaway data dir: tests never touch the real ID database, clock
# state or other stdpath("data") files, and parallel runs don't collide.
test:
	@d=$$(mktemp -d) && XDG_DATA_HOME=$$d nvim --headless -u tests/minimal_init.lua -l tests/run.lua $(SPEC); \
	s=$$?; rm -rf $$d; exit $$s

# stylua, then the source rules of scripts/lint_sources.lua
lint:
	stylua --check lua plugin ftplugin syntax tests
	nvim --headless --clean -l scripts/lint_sources.lua lua

# stylua sometimes needs a second pass to settle
format:
	stylua lua plugin ftplugin syntax tests && stylua lua plugin ftplugin syntax tests

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
