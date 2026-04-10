.PHONY: install install-tools check precommit precommit-all hooks up dn destroy prepare-release

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

up:
	@bash scripts/createCluster.sh

dn:
	pulumi dn -y
	
destroy:
	./scripts/destroyCluster.sh


prepare-release:
	@bash scripts/prepareRelease.sh