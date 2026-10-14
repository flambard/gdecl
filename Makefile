# gdecl's own targets. Applications don't use this file; they include gdecl.mk.

test:
	$(MAKE) -C test test

bench:
	$(MAKE) -C test bench

clean:
	$(MAKE) -C test clean

.PHONY: test bench clean
