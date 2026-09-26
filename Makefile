.PHONY: test lint media

# A throwaway data dir: tests never touch the real ID database, clock
# state or other stdpath("data") files, and parallel runs don't collide.
test:
	@d=$$(mktemp -d) && XDG_DATA_HOME=$$d nvim --headless -u tests/minimal_init.lua -l tests/run.lua $(SPEC); \
	s=$$?; rm -rf $$d; exit $$s

lint:
	stylua --check lua plugin ftplugin syntax tests

# Re-record the README GIFs and screenshots (needs vhs and the
# BlexMono Nerd Font; see docs/media/README.md).
media:
	@for t in docs/media/tapes/*.tape; do \
	  case $$t in */common.tape) ;; *) vhs $$t & ;; esac; \
	done; wait
