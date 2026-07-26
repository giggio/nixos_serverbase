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
# driver time out rather than fail - the guest shells stop answering long before any assertion is reached. Most checks
# default `virtualisation.cores` to 1 (the nixos test driver's own default), so 4 at a time is one vCPU per physical
# core on a 4-core box - already the ceiling before the host is oversubscribed. A few checks ask for more themselves
# (gmktec1's boot and forgejo-runner checks both set `cores = 2`), so even at this number two of those landing in the
# same batch oversubscribes slightly; that is tolerated, going higher is not.
check_jobs ?= 4

# Cores nix itself may hand to a single derivation's own build step (distinct from a check's `virtualisation.cores`,
# which sizes the qemu guest, not the build). Left at nix's own default (0, meaning "all available"), one derivation
# that happens to compile something - a kernel, a package with no cached substitute - can burst across every core
# while $(check_jobs) other checks are already running their VMs, which is the more likely reason raising check_jobs
# stopped being safe than vCPU count alone. Pinning it to 1 keeps every concurrent build to its fair share.
check_cores ?= 1

# Wall clock per check, in seconds. The in-driver watchdog (tests/lib/diagnostics.nix) catches a driver that stops
# making progress, but nothing there catches a guest that keeps answering while getting nowhere, or a build that never
# reaches the driver at all. Without this such a check holds one of the $(check_jobs) slots for the whole run.
check_timeout ?= 3600

check_out_dir := $(out_dir)/checks

check_names_cmd = nix eval --raw --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)' .\#checks.$(architecture)-linux

.PHONY: checks full_checks checks_report list_checks dirty_checks cache_checks test

### Tests

## Runs a quick boot test
test: check_boot-test

## Lists the checks this flake defines
list_checks:
	@$(check_names_cmd); echo

# Run like this to use every core:
# make checks check_jobs=$(nproc) check_cores=1
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
	      --no-link --print-build-logs --cores $(check_cores) --timeout $(check_timeout) > "$$log" 2>&1; then \
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
	  --no-link --print-build-logs --cores $(check_cores) --timeout $(check_timeout) 2>&1 | tee "$(check_out_dir)/$*.log"

# A check that has passed once is a realised store path, so every later `nix build` of it is a no-op that prints
# nothing and exits 0. That is what makes a suite cheap to re-run, and it also means a check cannot be run twice to
# see whether it is flaky - "I ran it three times" is three cache hits. `--rebuild` builds it again for real.
## Re-runs one check even though it is cached, e.g. `make recheck_opi4pronas-jellyfin`
recheck_%:
	@mkdir -p "$(check_out_dir)"
	@set -o pipefail; \
	{ \
	  nix build ".#checks.$(architecture)-linux.$*" --no-link --print-build-logs \
	    --cores $(check_cores) --timeout $(check_timeout) 2>&1 \
	  && printf '\n=== that was the first build of this check; running it again ===\n\n' \
	  && nix build ".#checks.$(architecture)-linux.$*" --no-link --print-build-logs --rebuild \
	    --cores $(check_cores) --timeout $(check_timeout) 2>&1; \
	} | tee "$(check_out_dir)/$*.log"

# Same run as `checks`, under a name meant for a crontab or systemd timer rather than a terminal: it is the full
# sweep that catches whatever a per-push run of just the affected checks (see `dirty_checks`) could miss - a check
# nix considers unaffected because no input it tracks changed, but whose result still depends on something outside
# that tracking (a docker image pulled at test time, a flaky assertion). Nothing here differs from `checks` itself;
# the separate name exists so a schedule invokes something self-documenting instead of the same target a person runs
# interactively.
## Runs every check unconditionally - meant for a schedule, not the terminal
full_checks: checks

# What actually would run for the checks a schedule should not need to wait for. `nix build --dry-run` against a check
# that is already realised for the current inputs prints nothing at all; against one where anything changed underneath
# it - the check itself, a shared module fifteen imports away, the machine it boots - it names every derivation that
# would have to be rebuilt. That is a more reliable "what does this change affect" than a hand-written file-to-test
# map: the map has to be maintained by hand and drifts, this reads it straight off the dependency graph nix already
# has, transitively, for free.
# Run with the number of processsors at a time: a dry-run re-evaluates the whole flake from scratch (nixpkgs, every module,
# every other check) just to answer one name, so a serial loop over thirty of them pays that cost thirty times over and is the
# slower half of this target, not the qemu-free half being asked for. Evaluation is memory-bound rather than
# vCPU-bound, so it does not carry the same oversubscription risk `check_jobs` exists to bound for actual VM boots.
dirty_checks:
	@names=$$($(check_names_cmd)) || exit 1; \
	report() { \
	  name="$$1"; \
	  output=$$(nix build ".#checks.$(architecture)-linux.$$name" --dry-run 2>&1 >/dev/null); \
	  case "$$output" in \
	    *"will be built"*) echo "$$name" ;; \
	    *error:*) echo "$$name (dry-run itself failed - see \`make check_$$name\`)" >&2; echo "$$name" ;; \
	  esac; \
	}; \
	export -f report; \
	printf '%s\n' $$names | xargs -P $$(nproc) -n1 $(SHELL) -c 'report "$$0"'

## Pushes one check's result to the cache, e.g. `make cache_check_gmktec1-boot` - builds it first if needed
cache_check_%:
	@echo -e "Pushing cache for check \e[32m$*\e[0m"
	nix build ".#checks.$(architecture)-linux.$*" --no-link --print-out-paths --cores $(check_cores) --timeout $(check_timeout) | attic push servers --stdin

## Pushes every check's result to the cache, check_jobs at a time - so a later run elsewhere can substitute instead
## of re-running a check nothing has invalidated
cache_checks:
	@names=$$($(check_names_cmd)) || exit 1; \
	printf '%s\n' $$names | xargs -P $(check_jobs) -I{} $(MAKE) --no-print-directory cache_check_{}

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
