instances=$(shell find ./tests -maxdepth 1 -type f -name '*.yml')

.PHONY: all-golden-diff
golden-diff-all: recursive_target=golden-diff
golden-diff-all: $(instances) ## Run golden-diff for all instances. Note: this doesn't work when running make with multiple parallel job (-j != 1).

.PHONY: all-golden-diff
gen-golden-all: recursive_target=gen-golden
gen-golden-all: $(instances) ## Run gen-golden for all instances. Note: this doesn't work when running make with multiple parallel job (-j != 1).

.PHONY: $(instances)
$(instances):
	$(MAKE) $(recursive_target) -e instance=$(basename $(@F))
