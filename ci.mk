# Running the Forgejo workflows locally, one `ci_<name>` target per file in .forgejo/workflows.
#
# Included by the Makefile, so the targets are whichever workflows the repository `make` runs in has: serverbase's own
# here, the superproject's in a superproject that includes that Makefile.
#
# Why a snapshot: `forgejo-runner exec` does not check out anything, it `docker cp`s the working directory into the
# container, and with its default of honouring .gitignore that copy leaves out every `.git`. Nothing that runs git then
# works (the workflows' `git diff`, nix's `git+file` inputs, the submodules). So the repository is copied to a scratch
# directory and handed over whole, `.git` included (`--use-gitignore=false`). The copy is also why that is safe: git
# refreshes the index and nix updates the lock files in it, and nothing here writes to the real tree. It is also what
# makes it work where a submodule is a bindfs mount, whose `.git` is real in the copy.
#
# The jobs are named on the command line because the runner picks them by the workflow's trigger, and a scheduled or
# manually dispatched workflow has no `push` job to pick.
#
# Only the two attic secrets are set. A step that needs another one (the one that opens the pull request) fails, which
# is what a local run should do.

ci_workflows_dir ?= .forgejo/workflows
ci_targets := $(addprefix ci_,$(basename $(notdir $(wildcard $(ci_workflows_dir)/*.yaml))))
attic_config ?= $(HOME)/.config/attic/config.toml
attic_server ?= home

.PHONY: $(ci_targets)
### CI

# smoke.yaml runs on the docker label and names its own image, so exec needs no label mapping. --use-gitignore=false
# keeps .git, which the superproject's submodule checkout needs.
# Not from inside the superproject's nixos_serverbase directory: there .git is a file pointing at
# ../.git/modules/nixos_serverbase, the runner copies only this directory, and nix then cannot open the repository.
# Run it from the superproject, or from a standalone clone of this repository.
## Runs the smoke workflow locally on the working tree in Docker
ci:
	nix run nixpkgs#forgejo-runner -- exec --event push --workflows .forgejo/workflows/smoke.yaml --use-gitignore=false

## Run the .forgejo/workflows/<name>.yaml workflow locally, in a snapshot of the repository
$(ci_targets): ci_%: $(ci_workflows_dir)/%.yaml
	@set -euo pipefail; \
	attic_endpoint="$$(yq '.servers.$(attic_server).endpoint' $(attic_config))"; \
	ATTIC_TOKEN="$$(yq '.servers.$(attic_server).token' $(attic_config))"; \
	for value in "$$attic_endpoint" "$$ATTIC_TOKEN"; do \
		if [ -z "$$value" ] || [ "$$value" = null ]; then \
			>&2 echo "No servers.$(attic_server) endpoint and token in $(attic_config)"; exit 1; \
		fi; \
	done; \
	export ATTIC_TOKEN; \
	snapshot="$$(mktemp -d --tmpdir ci-snapshot.XXXXXXXXXX)"; \
	trap 'rm -rf --one-file-system "$$snapshot"' EXIT; \
	rsync -a --exclude=/$(out_dir) --exclude=/result ./ "$$snapshot/"; \
	jobs=(); \
	while IFS= read -r job; do jobs+=(--job "$$job"); done < <(yq '.jobs | keys | .[]' "$(ci_workflows_dir)/$*.yaml"); \
	cd "$$snapshot"; \
	nix run nixpkgs#forgejo-runner -- exec --workflows "$(ci_workflows_dir)/$*.yaml" "$${jobs[@]}" \
		--use-gitignore=false -C "$$snapshot" \
		--secret ATTIC_ENDPOINT="$$attic_endpoint" --secret ATTIC_TOKEN
