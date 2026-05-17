.PHONY: install install-tools check precommit precommit-all hooks up dn destroy shutdown prepare-release

install: install-tools
	# npm packages (requires mounted filesystem for package.json)
	npm ci
	# ensure nested submodules are available on fresh clones
	git submodule update --init --recursive

install-tools:
	bash scripts/install.sh

check:
	npx tsc --noEmit 2>&1

precommit-all:
	npx prettier --write "**/*.ts"
	npx tsc --noEmit 2>&1

precommit:
	@bash scripts/precommit.sh

hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit

create:
	@bash scripts/createCluster.sh

up: 
	pulumi up -y
	@bash scripts/getKubeConfig.sh

dn:
	@printf "Run pulumi up -y before pulumi dn -y? [y/N] "; \
	read run_up; \
	if [ "$$run_up" = "y" ] || [ "$$run_up" = "Y" ]; then \
		echo "Running pulumi up -y..."; \
		pulumi up -y; \
	fi; \
	pulumi dn -y
	
shutdown:
	@bash scripts/shutdownCluster.sh

destroy:
	./scripts/destroyCluster.sh


prepare-release:
	@bash scripts/prepareRelease.sh