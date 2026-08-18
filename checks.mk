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
# driver time out rather than fail - the guest shells stop answering long before any assertion is reached. Every check
# leaves `virtualisation.cores` at the test driver's default of 1, so 4 at a time is one vCPU per physical core on a
# 4-core box - already the ceiling before the host is oversubscribed. A check that asks for more than one vCPU is not
# accounted for here, so anything that starts doing so should be weighed against this number.
#
# This bounds vCPUs and nothing else. Memory is bounded separately, by $(check_memory) below, and on any host that is
# not a roomy workstation that is the bound that actually binds.
check_jobs ?= 4

# Memory, in MiB, that the checks running at once may add up to - each one counted as its nodes' `memorySize` plus
# $(check_overhead). The second bound, and the one a count alone cannot express, since nothing says the checks are
# the same size.
#
# The absence of this bound killed the weekly update run of 2026-08-04 on gmktec1, whose runner shares its 8G with
# everything that machine serves. The checks then declared 4G each (gmktec1's boot check 6G, pi4-servarr-live 8G), so
# the four alphabetically first ones - exactly what a flat `-P 4` starts with - came to 18G of guest memory before a
# single service inside them had started. The kernel OOM killer took 13 checks one at a time, and since it sends
# SIGKILL, each log just stopped mid-boot with nothing in it: 14 failures, not one log naming a failure. Those
# declarations have since been measured and cut to a uniform 1536, which is the other half of the fix - this bound is
# what keeps the next such regression from being silent rather than what makes the suite fit.
#
# Read off the host instead of written down, because the same suite runs on a workstation and on a server, and on the
# server what is free depends on what the server is doing at the time. MemAvailable rather than MemTotal for the same
# reason: the question is what can be taken without evicting the services. The fraction is headroom for a guest that
# overshoots and for everything qemu allocates outside the guest.
check_memory ?= $(shell awk '/^MemAvailable:/ { available = $$2 } END { printf "%d", (available ? available * 0.7 / 1024 : 8192) }' /proc/meminfo)

# What one check costs on top of its guests, in MiB. Each one runs its own `nix build`, which evaluates this flake -
# the machine configurations included - before it starts a VM, and then stays resident for as long as the VM runs.
# Measured with `/usr/bin/time -v nix eval --no-eval-cache ...drvPath` over a spread of checks: 0.9G for the
# cheapest, 1.3G for gmktec1-nextcloud. This is not a rounding error next to a 1G guest, and it is the process the
# OOM killer actually picked every time in the run above, qemu having faulted in only part of what it asked for.
check_overhead ?= 1024

# What one of `eval`'s evaluators costs, in MiB - deliberately NOT $(check_overhead), which is a third of it. That
# figure is measured over checks; `eval` also evaluates `packages`, where the install media live, and an ISO wraps a
# machine in an installer carrying its own nested `lib.nixosSystem`, so evaluating one holds TWO whole systems live.
# Measured the same way over all 85 attributes: 0.97G mean, 1.3G for the worst check, 2.81G for gmktec1_iso. The four
# `*_iso` packages are the only things in this flake anywhere near that, and they are what sets this number - on a
# host small enough for it to bind, one of them is the whole budget.
eval_overhead ?= 3072

# Processes of $(1) MiB that fit in $(check_memory): never more than there are cores to run them on, never fewer than
# one, since there is no lower gear than serial and a box too small for even one still has to try.
jobs_that_fit = $(shell jobs=$$(( $(check_memory) / $(1) )); cores=$$(nproc); \
  [ "$$jobs" -lt 1 ] && jobs=1; [ "$$jobs" -gt "$$cores" ] && jobs=$$cores; echo "$$jobs")

eval_jobs ?= $(call jobs_that_fit,$(eval_overhead))

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

# Extra flags handed to every `nix` invocation in this file. Empty by default, so nothing changes for an ordinary run.
#
# What it is for: in a superproject that consumes this repository as a `git+file:` flake input, a build sees only the
# COMMITTED submodule at the locked revision. Editing a module here and running `make checks` there therefore tests
# the old code and passes, silently, which is the worst possible outcome for a test suite. The documented way round
# it is `--override-input`, and without a hook like this there is no way to give that to the suite:
#
#     make checks nix_flags='--override-input serverbase path:/home/giggio/.config/nixos/nixos_serverbase'
#
# A variable rather than anything cleverer, because this repository has to keep working standalone, where there is no
# superproject and no input to override.
#
# Interpolated AFTER the subcommand (`nix eval $(nix_flags)`, not `nix $(nix_flags) eval`): `--override-input` and
# most of what would go here belong to the subcommand, and nix rejects them outright in the global position.
nix_flags ?=

check_names_cmd = nix eval $(nix_flags) --raw --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)' .\#checks.$(architecture)-linux

# `<name> <MiB>` per check, for the scheduler in `checks`. A nixosTest carries its nodes on the derivation it
# produces, so what a check will ask qemu for is readable without building anything; a check that is a plain
# derivation has no `nodes` and boots nothing, and is charged $(check_overhead) alone. One evaluation answers for
# every check at once, which is the only reason this is affordable - it costs about what one check's own `nix build`
# spends evaluating, and it is paid before any VM starts, so it contends with nothing.
#
# A node's options are read off the node itself. The `node.config` that also resolves is the compatibility attribute
# the test framework keeps for pre-22.11 tests, and touching it prints a deprecation warning per node - which here
# means one for every node of every check, ahead of every `make checks` run.
check_memory_cmd = nix eval $(nix_flags) --raw --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (name: check: name + " " + builtins.toString (if check ? nodes then builtins.foldl'\'' (total: node: total + node.virtualisation.memorySize) 0 (builtins.attrValues check.nodes) else 0)) cs))' .\#checks.$(architecture)-linux

machine_names_cmd = nix eval $(nix_flags) --raw --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)' .\#nixosConfigurations

# The VM images, the install media and the helper packages - everything `nix build .#<x>` reaches that is not a check.
# Only `eval` uses this; see the comment there for why the install images especially need to be in it.
package_names_cmd = nix eval $(nix_flags) --raw --apply 'ps: builtins.concatStringsSep "\n" (builtins.attrNames ps)' .\#packages.$(architecture)-linux

.PHONY: checks full_checks checks_report list_checks dirty_checks cache_checks test eval lint_md lint_md_all

### Tests

## Runs a quick boot test
test: check_boot-test

## Lints the markdown this working tree has TOUCHED - staged, unstaged and untracked - against
## .markdownlint-cli2.jsonc. Run it from whichever repository you are changing; each has its own config, and the
## submodule is a separate git tree so its files are not in the superproject's diff.
##
## Deliberately not every file in the repository. A whole-repo sweep on a tree that has never been linted reports on
## files the current change never came near, and the only ways out of that are to commit unrelated fixes or to
## ignore the output - both worse than a narrow check that is always green. `lint_md_all` is there for the one
## commit that cleans up the rest.
lint_md:
	@files=$$({ git diff --name-only --diff-filter=d HEAD -- '*.md'; \
	            git ls-files --others --exclude-standard -- '*.md'; } | sort -u); \
	if [ -z "$$files" ]; then echo "no markdown changed in this working tree"; exit 0; fi; \
	echo "$$files" | sed 's/^/  linting /'; \
	markdownlint-cli2 --no-globs $$files

## Lints every markdown file in the repository. For the sweep commit, not for everyday work - see lint_md.
lint_md_all:
	@markdownlint-cli2

## Lists the checks this flake defines
list_checks:
	@$(check_names_cmd); echo

# Every machine's toplevel, every check's derivation and every package, forced but not built. The cheapest rung of
# the ladder `eval` -> `dirty_checks` -> `checks`: it builds nothing, boots nothing and needs no /dev/kvm, so it costs
# minutes against the hour the full suite takes - and it is still where nearly everything that breaks this repository
# shows up, since a renamed option, a failed assertion, a module that stopped typechecking or a machine the tests no
# longer match are all evaluation errors. Printing the derivation path is what forces it.
#
# `packages` is in the list because leaving it out cost real breakage: the install images (`opi4pro_img`,
# `opi4pronas_img`) could not evaluate AT ALL for an unknown length of time, and nothing noticed. Nothing else covers
# them. `nixosConfigurations` is a different attribute - an image wraps a machine in an sd-image/ISO builder with its
# own nested `lib.nixosSystem`, and it was that nested system, not any machine, that was broken. `make checks` boots
# machines and never builds an image; build.yaml's `make out/nix/system` builds the systems and not the media. So an
# image is exercised only when someone reinstalls a server, which is exactly when a broken one is most expensive.
#
# It is deliberately the whole `packages` attribute set rather than a filtered subset. The `machine_*` packages
# duplicate work `nixosConfigurations` already did, which is a few seconds; a filter is a thing that silently stops
# matching, which is the failure mode this whole target exists to catch.
#
# ONE PROCESS PER ATTRIBUTE, deliberately, even though a single `nix eval` over the whole attribute set would share
# all the work between them and finish sooner. Sharing the work also means holding every evaluated configuration live
# at once: measured, that peaks at 18G over 26 machines, which is comfortable on a workstation and was killed
# outright on the 8G box that runs CI - `make eval` died with `Error 137` there while passing here. One attribute at
# a time is bounded by $(eval_overhead), so the cost is bounded rather than proportional to how much this flake grows.
#
# xargs exits non-zero when any invocation did, which is what fails this target; the inner function has to report the
# failure itself, because `nix eval` writes the error to stderr and xargs would otherwise swallow which one it was.
#
# `nix flake check --no-build` is the obvious thing and does not work here: it also evaluates `nixosModules` as
# standalone modules, and those need `_module.args.inputs`, which only a machine gives them.
## Evaluates every machine, every check and every package, building and booting nothing
eval:
	@machines=$$($(machine_names_cmd)) || exit 1; \
	checks=$$($(check_names_cmd)) || exit 1; \
	packages=$$($(package_names_cmd)) || exit 1; \
	echo "evaluating $$(echo $$machines | wc -w) machines, $$(echo $$checks | wc -w) checks and $$(echo $$packages | wc -w) packages, $(eval_jobs) at a time"; \
	eval_one() { \
	  attribute="$$1"; \
	  if drv=$$(nix eval $(nix_flags) --raw ".#$$attribute.drvPath"); then \
	    printf '%s %s\n' "$$attribute" "$$drv"; \
	  else \
	    echo "FAILED to evaluate $$attribute" >&2; \
	    return 1; \
	  fi; \
	}; \
	export -f eval_one; \
	{ printf 'nixosConfigurations.%s.config.system.build.toplevel\n' $$machines; \
	  printf 'checks.$(architecture)-linux.%s\n' $$checks; \
	  printf 'packages.$(architecture)-linux.%s\n' $$packages; \
	} | xargs -P $(eval_jobs) -n1 $(SHELL) -c 'eval_one "$$0"'

# Run like this to use every core, on a machine with the memory to back it:
# make checks check_jobs=$(nproc) check_cores=1 check_memory=$$((64 * 1024))
#
# The scheduler is a bin-packing loop rather than `xargs -P` because the second bound is a weight, not a count: a slot
# has to be given back with the size of the check that was in it, which is what the pid-to-cost map and `wait -n -p`
# are for. Largest first, so the big checks pack around the small ones instead of the small ones finishing early and
# leaving the biggest to run against a full budget at the end. A check bigger than the whole budget would otherwise
# never be startable, so the memory bound is skipped when nothing else is running - it runs alone, which is the most
# the host can do for it anyway.
## Runs every check, as many at a time as check_jobs and check_memory allow, each into its own log, then prints a
## pass/fail table
checks:
	@set -o pipefail; \
	schedule=$$($(check_memory_cmd)) || exit 1; \
	if [ -z "$$schedule" ]; then echo "this flake defines no checks" >&2; exit 1; fi; \
	rm -rf "$(check_out_dir)"; mkdir -p "$(check_out_dir)"; \
	checks_total=$$(printf '%s\n' "$$schedule" | wc -l); budget=$(check_memory); \
	echo "running $$checks_total checks, up to $(check_jobs) at a time within $$budget MiB; logs in $(check_out_dir)/"; \
	alone=$$(printf '%s\n' "$$schedule" | awk -v overhead=$(check_overhead) -v budget="$$budget" '$$2 + overhead > budget { n++ } END { print n + 0 }'); \
	if [ "$$alone" -gt 0 ]; then \
	  echo "  $$alone of them cost more than that on their own and will run alone; if any is killed, this host is too small for it"; \
	fi; \
	echo; \
	run_check() { \
	  name="$$1"; log="$(check_out_dir)/$$name.log"; started=$$SECONDS; \
	  if nix build $(nix_flags) ".#checks.$(architecture)-linux.$$name" \
	      --no-link --print-build-logs --cores $(check_cores) --timeout $(check_timeout) > "$$log" 2>&1 < /dev/null; then \
	    result=pass; status=0; \
	  else \
	    status=$$?; result=fail; \
	  fi; \
	  elapsed=$$((SECONDS - started)); \
	  printf '%s %s %s\n' "$$result" "$$elapsed" "$$status" > "$(check_out_dir)/$$name.result"; \
	  done_so_far=$$(ls "$(check_out_dir)"/*.result | wc -l); \
	  if [ "$$result" = pass ]; then \
	    printf '[%2s/%2s] \033[32mpass\033[0m  %s (%ss)\n' "$$done_so_far" "$$checks_total" "$$name" "$$elapsed"; \
	  else \
	    printf '[%2s/%2s] \033[31mFAIL\033[0m  %s (%ss)  %s\n' \
	      "$$done_so_far" "$$checks_total" "$$name" "$$elapsed" "$$log"; \
	  fi; \
	}; \
	declare -A running_memory; used=0; \
	while read -r name memory; do \
	  memory=$$((memory + $(check_overhead))); \
	  while [ $${#running_memory[@]} -ge $(check_jobs) ] \
	     || { [ $${#running_memory[@]} -gt 0 ] && [ $$((used + memory)) -gt $$budget ]; }; do \
	    wait -n -p finished; \
	    used=$$((used - running_memory[$$finished])); \
	    unset "running_memory[$$finished]"; \
	  done; \
	  run_check "$$name" & \
	  running_memory[$$!]=$$memory; used=$$((used + memory)); \
	done < <(printf '%s\n' "$$schedule" | sort -k2,2nr -k1,1); \
	wait; \
	$(checks_report_body)

## Reprints the table from the last `make checks`, without building anything
checks_report:
	@$(checks_report_body)

## Runs one check with its output on the terminal, e.g. `make check_gmktec1-nextcloud`
check_%:
	@mkdir -p "$(check_out_dir)"
	@set -o pipefail; \
	nix build $(nix_flags) ".#checks.$(architecture)-linux.$*" \
	  --no-link --print-build-logs --cores $(check_cores) --timeout $(check_timeout) 2>&1 | tee "$(check_out_dir)/$*.log"

# A check that has passed once is a realised store path, so every later `nix build` of it is a no-op that prints
# nothing and exits 0. That is what makes a suite cheap to re-run, and it also means a check cannot be run twice to
# see whether it is flaky - "I ran it three times" is three cache hits. `--rebuild` builds it again for real.
## Re-runs one check even though it is cached, e.g. `make recheck_opi4pronas-jellyfin`
recheck_%:
	@mkdir -p "$(check_out_dir)"
	@set -o pipefail; \
	{ \
	  nix build $(nix_flags) ".#checks.$(architecture)-linux.$*" --no-link --print-build-logs \
	    --cores $(check_cores) --timeout $(check_timeout) 2>&1 \
	  && printf '\n=== that was the first build of this check; running it again ===\n\n' \
	  && nix build $(nix_flags) ".#checks.$(architecture)-linux.$*" --no-link --print-build-logs --rebuild \
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
# Run several at a time: a dry-run re-evaluates the whole flake from scratch (nixpkgs, every module, every other
# check) just to answer one name, so a serial loop over thirty of them pays that cost thirty times over and is the
# slower half of this target, not the qemu-free half being asked for.
#
# How many is a memory question, not a vCPU one, which is why this is not simply `nproc`. There is no qemu here, so
# $(check_memory) is spent entirely on evaluators at $(check_overhead) each - about 1.2G apiece, measured. On a
# workstation that resolves to more than there are cores and `nproc` wins; on the 8G box that runs CI it resolves to
# two, and the difference is whether this target OOMs. `nproc` alone was the original value and would be four there.
dirty_jobs ?= $(call jobs_that_fit,$(check_overhead))
dirty_checks:
	@names=$$($(check_names_cmd)) || exit 1; \
	report() { \
	  name="$$1"; \
	  output=$$(nix build $(nix_flags) ".#checks.$(architecture)-linux.$$name" --dry-run 2>&1 >/dev/null); \
	  case "$$output" in \
	    *"will be built"*) echo "$$name" ;; \
	    *error:*) echo "$$name (dry-run itself failed - see \`make check_$$name\`)" >&2; echo "$$name" ;; \
	  esac; \
	}; \
	export -f report; \
	printf '%s\n' $$names | xargs -P $(dirty_jobs) -n1 $(SHELL) -c 'report "$$0"'

## Pushes one check's result to the cache, e.g. `make cache_check_gmktec1-boot` - builds it first if needed
# stderr is sent to its own log, same as `checks` does per-check, not to $$log - this recipe's stdout is
# the store path piped into `attic push`, so 2>&1 here would corrupt that stream. It is mainly nix's
# eval-cache SQLite chatter (harmless under xargs -P: N parallel `nix build`s share one eval-cache file
# keyed by flake revision, not by attribute, so they collide - nix already ignores the failed cache write
# itself) that this hides from the interleaved terminal output; a real build failure still fails the
# recipe and is on record in the log.
cache_check_%:
	@echo -e "Pushing cache for check \e[32m$*\e[0m"
	@mkdir -p "$(check_out_dir)"
	nix build $(nix_flags) ".#checks.$(architecture)-linux.$*" --no-link --print-out-paths --cores $(check_cores) --timeout $(check_timeout) 2>"$(check_out_dir)/cache_$*.log" | attic push servers --stdin

## Pushes every check's result to the cache, check_jobs at a time - so a later run elsewhere can substitute instead
## of re-running a check nothing has invalidated
cache_checks:
	@names=$$($(check_names_cmd)) || exit 1; \
	printf '%s\n' $$names | xargs -P $(check_jobs) -I{} $(MAKE) --no-print-directory cache_check_{}

# The table, and for every check that failed the lines that say why. A log path on its own is traceability only in the
# sense that the evidence exists somewhere; lifting the driver's `!!!` lines and nix's `error:` lines into the summary
# is what makes the common question - which assertion broke - answerable without a second command.
#
# The exit status is reported alongside, because the one failure the log cannot explain is the one where there is no
# log: a check killed by a signal - 137 is SIGKILL, which off a build host means the OOM killer - stops mid-line with
# nothing written after it, and without this reads as "failed for no stated reason".
define checks_report_body
set -o pipefail; \
if [ ! -d "$(check_out_dir)" ]; then echo "no check run to report on; run 'make checks'" >&2; exit 1; fi; \
passed=0; failed=0; failures=""; \
echo; \
for result_file in $$(ls "$(check_out_dir)"/*.result 2>/dev/null); do \
  name=$$(basename "$$result_file" .result); \
  read -r result elapsed status < "$$result_file"; \
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
  read -r _ _ status < "$(check_out_dir)/$$name.result"; \
  printf '\n\033[31m== %s ==\033[0m %s\n' "$$name" "$$log"; \
  if [ "$${status:-0}" -gt 128 ]; then \
    printf '    killed by signal %s%s\n' "$$((status - 128))" \
      "$$([ "$$status" = 137 ] && echo ' (SIGKILL - on a build host that is the OOM killer; see check_memory)')"; \
  fi; \
  reason=$$(grep -aE '!!!|AssertionError|watchdog fired|^error:|error: builder for|timed out after' "$$log" \
    | sed 's/^[^>]*> //' | awk '!seen[$$0]++' | head -n 20); \
  if [ -n "$$reason" ]; then printf '%s\n' "$$reason" | sed 's/^/    /'; \
  elif [ "$${status:-0}" -le 128 ]; then echo "    nothing in the log names a failure; read all of $$log"; fi; \
done; \
[ "$$failed" -eq 0 ]
endef
