.PHONY: install check backup precommit precommit-all hooks up destroy shutdown prepare-release create restore provision-edge

install: hooks
	# npm packages (requires mounted filesystem for package.json)
	npm ci
	# install more tools directly from github
	bash scripts/environment/install.sh

check:
	npx tsc --noEmit 2>&1

precommit-all:
	npx prettier --write "**/*.ts"
	npx tsc --noEmit 2>&1

precommit:
	bash scripts/environment/precommit.sh

hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit

create:
	bash scripts/pulumi/createCluster.sh new

restore:
	bash scripts/pulumi/createCluster.sh restore

# Second-pass on-premise edge provisioning (run after the VPN/mesh is up).
#   make provision-edge              # all edge nodes
#   make provision-edge ARGS=ubuntu-vm   # one node by id
provision-edge:
	bash scripts/pulumi/provisionEdgeNodes.sh $(ARGS)

up: 
	pulumi up -y
	bash scripts/runtime/getKubeConfig.sh

shutdown:
	bash scripts/pulumi/shutdownCluster.sh

backup:
	bash scripts/pulumi/backupCluster.sh

destroy:
	bash scripts/pulumi/destroyCluster.sh $(ARGS)

prepare-release:
	bash scripts/environment/prepareRelease.sh