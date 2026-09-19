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
#
# Bounded by $(check_reserve) as well as by the fraction, because a fraction alone does not bound what it leaves
# behind - see below.
check_memory ?= $(shell awk -v reserve=$(check_reserve) '/^MemAvailable:/ { available = $$2 } \
  END { \
    if (!available) { print 8192; exit } \
    mib = available / 1024; fraction = mib * 0.7; floor = mib - reserve; \
    budget = (fraction < floor ? fraction : floor); \
    printf "%d", (budget < 1 ? 1 : budget) \
  }' /proc/meminfo)

# Memory, in MiB, that $(check_memory) leaves unclaimed no matter how little the host has - an ABSOLUTE floor under
# the 0.7 fraction above, which is a relative one. Whichever of the two is tighter wins.
#
# A fraction bounds what the suite takes and therefore says nothing about what is left. At this workstation's size 30%
# of MemAvailable is many gigabytes of slack; in the smoke job's 4G kata guest, where MemAvailable reads ~3.63G, the
# same 30% is ~1.09G, and that has to cover the job container, the guest kernel, and the page cache of every store
# path `nix eval` substitutes and every flake input it unpacks. None of that is in the per-attribute costs, which are
# measured on a warm store where the fetching has already happened.
#
# Smoke run #148 (2026-09-18) is what this is for. `gmktec1-containers` and `gmktec1-forgejo` were charged
# 1131 * 1.15 = 1300 each from a stale $(eval_costs_file), so the pair came to 2600 against a 2602 budget and the
# scheduler started both - by two MiB. They had since grown to 1252, so the pair really took 2507, leaving 1589 MiB
# for everything above, and the guest OOM killer took the kata agent. It stops mid-log with no error of its own,
# because the agent is what carries the output; see the comment on $(eval_overhead).
#
# Regenerating the costs fixed that instance - the honest 1252 charges 1439, two no longer fit, the pair goes serial.
# It does not fix the class: the pair fit by two MiB, so the next ~10% of drift under a 15% margin puts some other
# pair in the same place. 1536 is bounded below by the only hard number the incident produced, that the untracked
# overhead exceeded 1589 MiB, and it binds where it is needed and nowhere else: the crossover is at
# $(check_reserve) / 0.3, so below ~5G of MemAvailable the reserve decides and above it the fraction still does. The
# workstation's budget is unchanged.
#
# A budget too small for even one attribute is not a failure mode - the schedulers skip the memory bound when nothing
# else is running, so the floor is serial, which is the most a host that small can do anyway.
check_reserve ?= 1536

# What one check costs on top of its guests, in MiB. Each one runs its own `nix build`, which evaluates this flake -
# the machine configurations included - before it starts a VM, and then stays resident for as long as the VM runs.
# Measured with `/usr/bin/time -v nix eval --no-eval-cache ...drvPath` over a spread of checks: 0.9G for the
# cheapest, 1.3G for gmktec1-nextcloud. This is not a rounding error next to a 1G guest, and it is the process the
# OOM killer actually picked every time in the run above, qemu having faulted in only part of what it asked for.
check_overhead ?= 1024

# What an evaluator is charged when nothing has measured it, in MiB - deliberately NOT $(check_overhead), which is a
# third of it. That figure is measured over checks; `eval` also evaluates `packages`, where the install media live,
# and an ISO wraps a machine in an installer carrying its own nested `lib.nixosSystem`, so evaluating one holds TWO
# whole systems live. Measured over all 93 attributes of the superproject: 1.03G mean, 1.8G for the worst check,
# 2.97G for gmktec1_iso. The four `*_iso` packages are the only things anywhere near that, and they are what sets
# this number.
#
# It is the FALLBACK, not the going rate. Charging every attribute the price of the most expensive one is what used
# to make this target serial on any host where the worst case does not fit twice - notably CI's 4G kata guest, where
# it fit exactly once and `make eval` therefore ran 93 evaluations end to end and outgrew the runner's timeout. What
# each attribute actually costs is measured into $(eval_costs_file) by `make eval_costs`; anything absent from that
# file - a machine added since it was last regenerated - is charged this and so can only ever be scheduled too
# conservatively, never too aggressively.
eval_overhead ?= 3072

# Measured peak RSS per attribute, `<attribute> <MiB>` per line, regenerated by `make eval_costs`. Lives in the
# flake root rather than here because the attribute names are the repository's, not this file's: this Makefile is
# included by superprojects whose machines it knows nothing about, so each repository carries its own table.
#
# Missing or stale is safe in one direction only. An attribute with no entry is charged $(eval_overhead), which is
# the maximum, so a table that has fallen behind schedules too little in parallel and wastes time. An attribute that
# has GROWN since it was measured is the direction that bites, which is what $(eval_cost_margin) is for.
eval_costs_file ?= eval-costs.txt

# Percent added to every measured cost. Absorbs the drift between a table regenerated now and the flake six months
# later, where a module has picked up an import or two and every machine costs a little more than it says here.
#
# Deliberately modest, because it is the SECOND helping of headroom and not the first: $(check_memory) is already
# MemAvailable times 0.7, so a run is bounded well below what the host actually has before this is applied at all.
# Stacking a generous margin on top of that fraction is not caution, it is a scheduler that will not schedule - at
# 25% two attributes of average cost came to 2640 MiB against CI's ~2590 MiB budget and the guest went back to
# running them one at a time, which is the entire problem this was meant to solve. At 15% they fit, the 1.8G checks
# still get a lane to themselves, and the ISOs still run alone.
eval_cost_margin ?= 15

# Processes of $(1) MiB that fit in $(check_memory): never more than there are cores to run them on, never fewer than
# one, since there is no lower gear than serial and a box too small for even one still has to try.
jobs_that_fit = $(shell jobs=$$(( $(check_memory) / $(1) )); cores=$$(nproc); \
  [ "$$jobs" -lt 1 ] && jobs=1; [ "$$jobs" -gt "$$cores" ] && jobs=$$cores; echo "$$jobs")

# The COUNT bound on `eval`, the memory bound being $(check_memory) applied per attribute by the scheduler. One
# evaluator per core: they are CPU-bound single-threaded processes, so more than that only makes them take turns.
eval_jobs ?= $(shell nproc)

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

# Drops the architecture-free aliases from a set of attribute names, leaving one name per derivation.
#
# `mkNixosConfigurations` publishes every machine twice: once as `<name><arch><variant>`, and once as
# `<name><variant>` assigned to the SAME value, so a person - and `nixos-rebuild` inside the machine, which derives
# the attribute from the hostname - can type a name with no architecture in it. `mkInstallerPackages` does the same
# for `<name>_iso`. They are aliases in the Nix sense, the identical thunk under two names, so evaluating both means
# starting a second process to compute a derivation the first one already produced. In this superproject that was 19
# of 93 attributes, two of them the install ISOs, which are the most expensive attributes there are.
#
# An alias is recognised by construction rather than by comparing values, which is the thing that cannot be done
# without evaluating: a name is an alias when some OTHER name in the same set becomes it once the architecture is
# taken out. That direction matters. If the naming convention ever moves, no name maps onto another, nothing is
# recognised as an alias and everything is evaluated - the same way a stale $(eval_costs_file) schedules too little
# in parallel. This can waste time; it cannot silently drop an attribute nobody then checks.
#
# Only the spellings `mkNixosModuleName` can produce, which is `$${system}` minus "-linux" minus "_".
canonical_names = ns: let names = builtins.attrNames ns; archs = [ "x8664" "aarch64" ]; strip = n: builtins.replaceStrings archs (map (_: "") archs) n; aliased = builtins.filter (n: n != null) (map (n: let bare = strip n; in if bare != n && builtins.elem bare names then bare else null) names); in builtins.concatStringsSep "\n" (builtins.filter (n: !(builtins.elem n aliased)) names)

machine_names_cmd = nix eval $(nix_flags) --raw --apply '$(canonical_names)' .\#nixosConfigurations

# The VM images, the install media and the helper packages - everything `nix build .#<x>` reaches that is not a check.
# Only `eval` uses this; see the comment there for why the install images especially need to be in it.
package_names_cmd = nix eval $(nix_flags) --raw --apply '$(canonical_names)' .\#packages.$(architecture)-linux

.PHONY: checks full_checks checks_report list_checks dirty_checks cache_checks test eval eval_costs lint_md lint_md_all

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
# machines and never builds an image, and build.yaml's `make out/nix/system` builds the systems and not the media. So
# an image is exercised only when someone reinstalls a server, which is exactly when a broken one is most expensive.
# That argument is why the `_img` packages are in here and staying: nothing else reaches them at all.
#
# The `_iso` packages are the one exception, and only where a host says so through $(eval_skip) - build.yaml now runs
# `make out/nix/iso`, so on a host too small to evaluate one they are covered by something strictly better than this
# target, a real build. Everywhere else the default stands and they are evaluated here like everything else.
#
# Otherwise it is deliberately the whole `packages` attribute set rather than a filtered subset. The `machine_*`
# packages duplicate work `nixosConfigurations` already did, which is a few seconds; a filter is a thing that
# silently stops matching, which is the failure mode this whole target exists to catch. $(eval_skip) is not that
# filter: it is off unless a caller sets it, and the run prints the pattern it was given, so a pattern that has
# stopped matching anything is on screen rather than implied by a number nobody counted.
#
# ONE PROCESS PER ATTRIBUTE, deliberately, even though a single `nix eval` over the whole attribute set would share
# all the work between them and finish sooner. Sharing the work also means holding every evaluated configuration live
# at once: measured, that peaks at 18G over 26 machines, which is comfortable on a workstation and was killed
# outright on the 8G box that runs CI - `make eval` died with `Error 137` there while passing here.
#
# Scheduled by the same bin-packing loop as `checks`, and for the same reason: the bound that binds is a weight, not
# a count, so a slot has to be given back with the size of what was in it. It used to be a flat `xargs -P N` with N
# derived from the WORST attribute's cost, and that is a different thing than it sounds - it does not run N average
# attributes, it runs however many the most expensive one would allow. With four ISOs at ~2.9G setting the price and
# a mean of 1.03G, CI's 4G kata guest bought exactly one evaluator and ran all 93 in series, which is how this target
# grew past the runner's 30 minute timeout. Packed against real per-attribute costs the same guest fits two or three
# of the ordinary ones and still runs an ISO alone, which is all that was ever wanted.
#
# Largest first, so the expensive attributes pack around the cheap ones instead of the cheap ones finishing early and
# leaving an ISO to run against a full budget at the end. An attribute bigger than the whole budget would otherwise
# never be startable, so the memory bound is skipped when nothing else is running - it runs alone, which is the most
# the host can do for it anyway.
#
# Failures are collected in a file rather than by exit status, because `wait -n` reports one job at a time and the
# point of this target is to name EVERY attribute that failed in one run, not to stop at the first. `nix eval` writes
# its own error to stderr as it goes, so the transcript still says what was wrong with each.
#
# `nix flake check --no-build` is the obvious thing and does not work here: it also evaluates `nixosModules` as
# standalone modules, and those need `_module.args.inputs`, which only a machine gives them.
#
# $(eval_no_ifd) is what makes "building nothing" true rather than merely intended. An import from derivation -
# `builtins.readFile "${someDrv}/file"`, of which `cargoLock.lockFile = "${src}/Cargo.lock"` is the usual sighting -
# suspends evaluation, realises that derivation and resumes. That realisation is a build nobody asked for: it is not
# in $(eval_costs_file), so the packing above has not budgeted a byte for it, and it lands inside the evaluator that
# tripped it, at whatever moment that evaluator is already at its peak. On a workstation it is invisible; on CI's 4G
# guest, tripped from inside a ~3G ISO evaluation, it takes the guest with it. Refusing it here fails the offending
# attribute by name, in the second it takes to reach, instead of hours later somewhere with no memory to spare.
eval_no_ifd = --option allow-import-from-derivation false

# Attributes this target leaves out, as an extended regular expression matched against the whole attribute path
# (`packages.x86_64-linux.gmktec1_iso`, `nixosConfigurations.gmktec1x8664.config.system.build.toplevel`). Empty by
# default, so a plain `make eval` still covers everything.
#
# It exists for one case: a host too small for an attribute that is not too big to be wrong, only too big to fit.
# The bound here is the WORST attribute, not the average, because $(check_memory) is what decides whether a run
# starts and an attribute over budget is started anyway rather than never - there is no lower gear than alone. So one
# attribute that does not fit does not slow the run down, it stops it: CI's 4G guest spent 87 minutes inside a single
# 2.9G `gmktec1_iso` and finished none of the other 92.
#
# Skipping is a real loss of coverage and belongs where that trade is visible, which is the workflow that knows how
# big its guest is - not a default here. Write `$$` for a literal `$` if the pattern needs an end anchor, since make
# expands this like any other variable.
eval_skip ?=

## Evaluates every machine, every check and every package, building and booting nothing
eval:
	@machines=$$($(machine_names_cmd)) || exit 1; \
	checks=$$($(check_names_cmd)) || exit 1; \
	packages=$$($(package_names_cmd)) || exit 1; \
	schedule=$$({ printf 'nixosConfigurations.%s.config.system.build.toplevel\n' $$machines; \
	  printf 'checks.$(architecture)-linux.%s\n' $$checks; \
	  printf 'packages.$(architecture)-linux.%s\n' $$packages; \
	} | { if [ -n '$(eval_skip)' ]; then grep -Ev '$(eval_skip)'; else cat; fi; } \
	  | awk -v costs="$(eval_costs_file)" -v fallback=$(eval_overhead) -v margin=$(eval_cost_margin) ' \
	  BEGIN { while ((getline line < costs) > 0) { split(line, f, " "); if (f[1] != "") cost[f[1]] = f[2] } } \
	  { if ($$0 in cost) print $$0, int(cost[$$0] * (100 + margin) / 100), "measured"; \
	    else print $$0, fallback, "assumed" }'); \
	budget=$(check_memory); \
	total=$$(printf '%s\n' "$$schedule" | wc -l); \
	measured=$$(printf '%s\n' "$$schedule" | grep -c ' measured$$' || true); \
	echo "evaluating $$(echo $$machines | wc -w) machines, $$(echo $$checks | wc -w) checks and $$(echo $$packages | wc -w) packages,"; \
	echo "  up to $(eval_jobs) at a time within $$budget MiB; $$measured of $$total costed from $(eval_costs_file), the rest charged $(eval_overhead)"; \
	if [ -n '$(eval_skip)' ]; then echo "  leaving out everything matching '$(eval_skip)'"; fi; \
	if [ "$$measured" -eq 0 ]; then \
	  echo "  no measurements, so this run is as serial as the budget makes it - regenerate with 'make eval_costs'"; \
	fi; \
	failed=$$(mktemp); \
	eval_one() { \
	  local drv; \
	  if drv=$$(nix eval $(nix_flags) $(eval_no_ifd) --raw ".#$$1.drvPath"); then \
	    printf '%s %s\n' "$$1" "$$drv"; \
	  else \
	    echo "FAILED to evaluate $$1" >&2; \
	    echo "$$1" >> "$$failed"; \
	  fi; \
	  return 0; \
	}; \
	declare -A running_cost; used=0; \
	while read -r attribute cost _; do \
	  while [ $${#running_cost[@]} -ge $(eval_jobs) ] \
	     || { [ $${#running_cost[@]} -gt 0 ] && [ $$((used + cost)) -gt $$budget ]; }; do \
	    wait -n -p finished; \
	    used=$$((used - running_cost[$$finished])); \
	    unset "running_cost[$$finished]"; \
	  done; \
	  eval_one "$$attribute" & \
	  running_cost[$$!]=$$cost; used=$$((used + cost)); \
	done < <(printf '%s\n' "$$schedule" | sort -k2,2nr -k1,1); \
	wait; \
	if [ -s "$$failed" ]; then \
	  echo; echo "$$(wc -l < "$$failed") of $$total attributes failed to evaluate:" >&2; \
	  sed 's/^/  /' "$$failed" >&2; rm -f "$$failed"; exit 1; \
	fi; \
	rm -f "$$failed"

# Regenerates $(eval_costs_file). Serial and slow by construction - it is measuring peak RSS, and evaluators running
# alongside each other would be measuring the host's memory pressure rather than their own cost - so this is a
# maintenance target, run when machines have been added or when a CI guest starts running out of room, not part of
# any routine.
#
# `command time` is GNU time from the devshell, not the bash keyword; %M is peak RSS in KiB. `--no-eval-cache` is
# what makes the number mean anything: a cached `.drvPath` is answered out of the flake eval cache in a couple of
# hundred MiB, so measuring through a warm cache writes a table of numbers three to ten times under the real cost -
# which is the one direction this table must never be wrong in.
#
# The measured number is written raw, with no margin folded in: $(eval_cost_margin) is applied when the table is
# READ, so the headroom can be widened later without re-measuring anything.
## Measures what each attribute costs to evaluate and rewrites eval-costs.txt, which `eval` schedules against
eval_costs:
	@machines=$$($(machine_names_cmd)) || exit 1; \
	checks=$$($(check_names_cmd)) || exit 1; \
	packages=$$($(package_names_cmd)) || exit 1; \
	attributes=$$({ printf 'nixosConfigurations.%s.config.system.build.toplevel\n' $$machines; \
	  printf 'checks.$(architecture)-linux.%s\n' $$checks; \
	  printf 'packages.$(architecture)-linux.%s\n' $$packages; }); \
	total=$$(printf '%s\n' "$$attributes" | wc -l); \
	echo "measuring $$total attributes one at a time; this is as slow as a serial 'make eval'"; \
	: > "$(eval_costs_file).new"; \
	n=0; \
	while read -r attribute; do \
	  n=$$((n + 1)); \
	  peak=$$(command time -f %M nix eval $(nix_flags) --no-eval-cache --raw ".#$$attribute.drvPath" 2>&1 >/dev/null | tail -1); \
	  case "$$peak" in ''|*[!0-9]*) \
	    echo "[$$n/$$total] could not measure $$attribute, leaving it to the fallback" >&2; continue ;; \
	  esac; \
	  mib=$$((peak / 1024)); \
	  printf '%s %s\n' "$$attribute" "$$mib" >> "$(eval_costs_file).new"; \
	  printf '[%2s/%2s] %5s MiB  %s\n' "$$n" "$$total" "$$mib" "$$attribute"; \
	done < <(printf '%s\n' "$$attributes"); \
	sort -o "$(eval_costs_file)" "$(eval_costs_file).new"; rm -f "$(eval_costs_file).new"; \
	echo; echo "wrote $$(wc -l < "$(eval_costs_file)") costs to $(eval_costs_file)"

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
