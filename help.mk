# Help target for displaying available Makefile targets
# This file is included by the main Makefile

OUT_DIR ?= out

.PHONY: help
## Show this help message
help: $(OUT_DIR)/.make_help_data $(OUT_DIR)/.make_help_vars
	@awk -F'|' 'BEGIN { \
		while ((getline < "$(OUT_DIR)/.make_help_vars") > 0) { \
			if (match($$0, /^\^([^=]+)=\^(.*)$$/, m)) { \
				vars[m[1]] = m[2]; \
			} \
		} \
		close("$(OUT_DIR)/.make_help_vars"); \
	} \
	$$1 == "SECTION" { \
		printf "\n\033[1;33m%s\033[0m\n", $$2; \
		next \
	} \
	function print_row(target, desc) { \
		printf "\033[36m%-30s\033[0m %s\n", target, desc; \
	} \
	$$1 == "RAW" { \
		print_row($$2, $$3); \
		next \
	} \
	$$1 == "VAR" { \
		val = vars[$$2]; \
		if (val == "") val = $$2; \
		if (length(val) > 60 && index(val, " ") > 0) { \
			printf "%s\n", $$3; \
			n = split(val, v_arr, " "); \
			for (i = 1; i <= n; i++) { \
				printf "  \033[36m%s\033[0m\n", v_arr[i]; \
			} \
		} else { \
			print_row(val, $$3); \
		} \
		next \
	}' $(OUT_DIR)/.make_help_data

$(OUT_DIR)/.make_help_data: $(MAKEFILE_LIST)
	@mkdir -p $(OUT_DIR)
	@awk '/^###/ { print "SECTION|" substr($$0, 5); next } \
	/^##/ { \
		sub(/^##+[ \t]*/, ""); \
		if (h) h = h " " $$0; \
		else h = $$0; \
		next \
	} \
	/^[^=:]+:/ { \
		if (h) { \
			split($$0, a, ":"); \
			t = a[1]; \
			gsub(/^[ \t]+|[ \t]+$$/, "", t); \
			if (match(t, /\$$\(([^)]+)\)/, m)) { \
				print "VAR|" m[1] "|" h; \
			} else { \
				print "RAW|" t "|" h; \
			} \
			h = ""; \
		} \
		next \
	} \
	{ h = "" }' $(MAKEFILE_LIST) > $@

$(OUT_DIR)/.make_help_vars: $(OUT_DIR)/.make_help_data
	@vars=$$(awk -F'|' '$$1 == "VAR" { print $$2 }' $< | sort -u); \
	if [ -n "$$vars" ]; then \
		eval_cmd="print_vars:;"; \
		for v in $$vars; do \
			eval_cmd="$$eval_cmd echo \"^$$v=^\$$($$v)\";"; \
		done; \
		make -s --no-print-directory -f $(MAKEFILE_LIST) --eval "$$eval_cmd" print_vars > $@; \
	else \
		touch $@; \
	fi
