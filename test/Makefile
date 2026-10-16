# The tests of gdecl that run in Godot: a gdecl application (the ASDF system
# gdecl-test in lisp/) and a Godot project (project/) whose script
# run_tests.gd runs them. `make test` builds the library and runs the tests
# headless; it fails if a test fails, Godot crashes, or Godot reports leaks
# when it exits.

SYSTEM = gdecl-test
LIBRARY = project/bin/libgdecl.so

include ../gdecl.mk

TEST_LOG = $(BUILD_DIR)/test.log

# Godot loads the extensions listed in this file, which the editor writes when
# it scans the project. The tests don't need the editor, so it's written here.
project/.godot/extension_list.cfg:
	@mkdir -p $(dir $@)
	echo "res://gdecl-test.gdextension" > $@

# The whole output, with --verbose for the details of leaks, is in TEST_LOG;
# the test results, errors and warnings are shown. An error that a test causes
# on purpose comes after the line "[test] expect error", and is shown as
# expected; any other error fails the run, also one at exit, e.g. from the
# framework's shutdown steps in the wrong order (lifecycle.lisp).
test: all project/.godot/extension_list.cfg
	@status=0; \
	$(GODOT) --headless --verbose --path project -s res://run_tests.gd > $(TEST_LOG) 2>&1 || status=$$?; \
	awk '/^\[test\] expect error$$/ { expect = 1; next } \
	     /^\[test\]/ { print; next } \
	     /^ERROR: / && expect { sub(/^ERROR: /, ""); print "[test] expected error: " $$0; getline; expect = 0; next } \
	     /^(ERROR|WARNING|SCRIPT ERROR)/ { print; getline; print }' $(TEST_LOG); \
	if awk '/^\[test\] expect error$$/ { expect = 1; next } \
	        /^ERROR: / && expect { expect = 0; next } \
	        /^(ERROR|SCRIPT ERROR)/ { found = 1 } \
	        END { exit !found }' $(TEST_LOG); then \
	  echo "[test] FAIL: Godot reported errors that no test expected (see above)"; status=1; \
	fi; \
	if grep -aq 'Leaked instance\|ObjectDB instances leaked\|still in use at exit\|Orphan StringName' $(TEST_LOG); then \
	  grep -a 'Leaked instance\|still in use\|Orphan StringName' $(TEST_LOG); \
	  echo "[test] FAIL: Godot reported leaks at exit (see $(TEST_LOG))"; status=1; \
	fi; \
	if [ $$status -ne 0 ]; then echo "[test] FAILED"; else echo "[test] PASSED"; fi; \
	exit $$status

# The benchmarks, see run_benchmarks.gd. The whole output is in BENCH_LOG.
BENCH_LOG = $(BUILD_DIR)/bench.log

bench: all project/.godot/extension_list.cfg
	@$(GODOT) --headless --path project -s res://run_benchmarks.gd > $(BENCH_LOG) 2>&1; \
	grep -a '^\[bench\]\|^ERROR\|^SCRIPT ERROR' $(BENCH_LOG)

.PHONY: test bench
