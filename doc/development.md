# Development

## Pre-commit checks

- This repo uses a local Git hooks directory at `.githooks/`.
- Activate it in each clone with `make hooks`.
- The `pre-commit` hook runs `make precommit`, which only processes staged `*.ts` files.
- `make precommit` formats staged TypeScript files, re-stages them, then runs `npx tsc --noEmit`.
- To run checks on all TypeScript files manually, use `make precommit-all`.
- As users will customize domains, there is a script 'scripts/environment/prepareRelease.sh' which replaces custom domains with "domain.tld" in the project_settings.ts and propagates this to argocd-deployments ('/deployment'). The script is meant to be run before creating a release and will change the domain back to your setting after you committed.

ToDo:
Note that there is the prepare release script which replaces the custom domains with "domain.tld" in the project_settings.ts and propagates this to argocd-deployments ('/deployment'). The script is meant to be run before creating a release and will change the domain back to your setting after you committed. This is necessary because users will customize the domains and we cannot have those in the released codebase.

## External gits

It is often very useful to have the source code of used applications within the same repository, e.g. for debugging or AI-assisted code understanding.

Invoke bash`scripts/environment/checkoutExternalGits.sh` to clone several external gits into the 'external' folder (git-ignored).
