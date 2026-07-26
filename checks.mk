# Running the flake's checks.
#
# Included by the Makefile, so it behaves the same here and in any superproject that includes that Makefile: the check
# names come from whichever flake `make` runs in.
#
# Why it exists: `nix build` given thirty VM tests prefixes every line of every one of them with its derivation name
# and interleaves them into a single stream, so a run produces tens of thousands of lines in no useful order and the
# only thing its exit status says is "something failed". Here every check is built on its own, into its own log, and
# the run ends with a table. A red row names one file that holds that test and nothing else.

# How many checks to build at once. Every check is a VM, and starting all of them together is what makes the test
# driver time out rather than fail - the guest shells stop answering long before any assertion is reached.
check_jobs ?= 4

# Wall clock per check, in seconds. The in-driver watchdog (tests/lib/diagnostics.nix) catches a driver that stops
# making progress, but nothing there catches a guest that keeps answering while getting nowhere, or a build that never
# reaches the driver at all. Without this such a check holds one of the $(check_jobs) slots for the whole run.
check_timeout ?= 3600

check_out_dir := $(out_dir)/checks
# `\#` because this is a variable assignment, where make would otherwise read the rest of the line as a comment. In a
# recipe `#` is passed through to the shell untouched, so the recipes below write it plain.
check_names_cmd = nix eval --raw --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)' \
  .\#checks.$(architecture)-linux

.PHONY: checks checks_report list_checks test

### Tests

## Runs a quick boot test
test: check_boot-test

## Lists the checks this flake defines
list_checks:
	@$(check_names_cmd); echo

## Runs every check, check_jobs at a time, each into its own log, then prints a pass/fail table
checks:
	@set -o pipefail; \
	names=$$($(check_names_cmd)) || exit 1; \
	if [ -z "$$names" ]; then echo "this flake defines no checks" >&2; exit 1; fi; \
	rm -rf "$(check_out_dir)"; mkdir -p "$(check_out_dir)"; \
	export checks_total=$$(echo $$names | wc -w); \
	echo "running $$checks_total checks, $(check_jobs) at a time; logs in $(check_out_dir)/"; \
	echo; \
	run_check() { \
	  name="$$1"; log="$(check_out_dir)/$$name.log"; started=$$SECONDS; \
	  if nix build ".#checks.$(architecture)-linux.$$name" \
	      --no-link --print-build-logs --timeout $(check_timeout) > "$$log" 2>&1; then \
	    result=pass; \
	  else \
	    result=fail; \
	  fi; \
	  elapsed=$$((SECONDS - started)); \
	  printf '%s %s\n' "$$result" "$$elapsed" > "$(check_out_dir)/$$name.result"; \
	  done_so_far=$$(ls "$(check_out_dir)"/*.result | wc -l); \
	  if [ "$$result" = pass ]; then \
	    printf '[%2s/%2s] \033[32mpass\033[0m  %s (%ss)\n' "$$done_so_far" "$$checks_total" "$$name" "$$elapsed"; \
	  else \
	    printf '[%2s/%2s] \033[31mFAIL\033[0m  %s (%ss)  %s\n' \
	      "$$done_so_far" "$$checks_total" "$$name" "$$elapsed" "$$log"; \
	  fi; \
	}; \
	export -f run_check; \
	printf '%s\n' $$names | xargs -P $(check_jobs) -n1 $(SHELL) -c 'run_check "$$0"'; \
	$(checks_report_body)

## Reprints the table from the last `make checks`, without building anything
checks_report:
	@$(checks_report_body)

## Runs one check with its output on the terminal, e.g. `make check_gmktec1-nextcloud`
check_%:
	@mkdir -p "$(check_out_dir)"
	@set -o pipefail; \
	nix build ".#checks.$(architecture)-linux.$*" \
	  --no-link --print-build-logs --timeout $(check_timeout) 2>&1 | tee "$(check_out_dir)/$*.log"

# A check that has passed once is a realised store path, so every later `nix build` of it is a no-op that prints
# nothing and exits 0. That is what makes a suite cheap to re-run, and it also means a check cannot be run twice to
# see whether it is flaky - "I ran it three times" is three cache hits. `--rebuild` builds it again for real.
## Re-runs one check even though it is cached, e.g. `make recheck_opi4pronas-jellyfin`
recheck_%:
	@mkdir -p "$(check_out_dir)"
	@set -o pipefail; \
	{ \
	  nix build ".#checks.$(architecture)-linux.$*" --no-link --print-build-logs \
	    --timeout $(check_timeout) 2>&1 \
	  && printf '\n=== that was the first build of this check; running it again ===\n\n' \
	  && nix build ".#checks.$(architecture)-linux.$*" --no-link --print-build-logs --rebuild \
	    --timeout $(check_timeout) 2>&1; \
	} | tee "$(check_out_dir)/$*.log"

# The table, and for every check that failed the lines that say why. A log path on its own is traceability only in the
# sense that the evidence exists somewhere; lifting the driver's `!!!` lines and nix's `error:` lines into the summary
# is what makes the common question - which assertion broke - answerable without a second command.
define checks_report_body
set -o pipefail; \
if [ ! -d "$(check_out_dir)" ]; then echo "no check run to report on; run 'make checks'" >&2; exit 1; fi; \
passed=0; failed=0; failures=""; \
echo; \
for result_file in $$(ls "$(check_out_dir)"/*.result 2>/dev/null); do \
  name=$$(basename "$$result_file" .result); \
  read -r result elapsed < "$$result_file"; \
  if [ "$$result" = pass ]; then \
    passed=$$((passed + 1)); \
    printf '  \033[32mpass\033[0m  %-34s %5ss\n' "$$name" "$$elapsed"; \
  else \
    failed=$$((failed + 1)); failures="$$failures $$name"; \
    printf '  \033[31mFAIL\033[0m  %-34s %5ss  %s\n' "$$name" "$$elapsed" "$(check_out_dir)/$$name.log"; \
  fi; \
done; \
printf '\n  %s passed, %s failed\n' "$$passed" "$$failed"; \
for name in $$failures; do \
  log="$(check_out_dir)/$$name.log"; \
  printf '\n\033[31m== %s ==\033[0m %s\n' "$$name" "$$log"; \
  reason=$$(grep -aE '!!!|AssertionError|watchdog fired|^error:|error: builder for|timed out after' "$$log" \
    | sed 's/^[^>]*> //' | awk '!seen[$$0]++' | head -n 20); \
  if [ -n "$$reason" ]; then printf '%s\n' "$$reason" | sed 's/^/    /'; \
  else echo "    nothing in the log names a failure; read all of $$log"; fi; \
done; \
[ "$$failed" -eq 0 ]
endef
