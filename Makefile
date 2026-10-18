# gdecl's own targets. Applications don't use this file; they include gdecl.mk.

test:
	$(MAKE) -C test test

bench:
	$(MAKE) -C test bench

clean:
	$(MAKE) -C test clean

# Checking that a change to the code generators (gd-extension/engine-methods.lisp,
# godot/engine-api.lisp) doesn't change the code they generate: make
# expansions-baseline before the change, make expansions-check after it. See
# test/expansions.lisp.
EXPANSIONS = test/build/expansions

expansions-baseline:
	@mkdir -p test/build
	ecl --norc --load test/expansions.lisp -- --out $(EXPANSIONS)-before.txt

expansions-check:
	@mkdir -p test/build
	ecl --norc --load test/expansions.lisp -- --out $(EXPANSIONS)-after.txt
	@if cmp -s $(EXPANSIONS)-before.txt $(EXPANSIONS)-after.txt; then \
	  echo "The generated code is unchanged"; \
	else \
	  echo "The generated code changed: diff $(EXPANSIONS)-before.txt $(EXPANSIONS)-after.txt"; \
	  exit 1; \
	fi

.PHONY: test bench clean expansions-baseline expansions-check
