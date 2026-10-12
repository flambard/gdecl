# gdecl's own targets. Applications don't use this file; they include gdecl.mk.

test:
	$(MAKE) -C test test

clean:
	$(MAKE) -C test clean

.PHONY: test clean
