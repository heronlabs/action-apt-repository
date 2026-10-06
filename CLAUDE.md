<!-- supera:guardrails -->
## Working with this repo (managed by /init — edits between these markers are overwritten on re-init)

- **Edit, don't rewrite.** Change only the needed entry in a config/generated file (`package.json`, lockfiles, manifests, CI yaml); preserve the rest. Never regenerate a whole file to add one line.
- **No scope creep.** Build only what was asked; no speculative abstractions, layers, or options. Prefer the simplest working solution.
- **Ambiguous literals: flag, don't guess.** Config keys, IDs, and env names can be literal values, not mappings. State which reading you took.
- **Scope a change to where it belongs** — most changes are localized to one area; touch other repos only when the change genuinely cuts across, and then update the related repos too.
<!-- /supera:guardrails -->

## Stack
- **Runtime**: POSIX sh (composite GitHub Action wrapping `heronlabs/action-web-server@v1`)
- **Test framework**: [BATS](https://github.com/bats-core/bats-core) — `tests/*.bats`, one file per script; runs the real `gpg`, `gpgv`, `apt-ftparchive` and `dpkg-deb`, and skips where they are missing (macOS)
- **Linter**: [shellcheck](https://www.shellcheck.net/) — all shell scripts + test files + mocks
- **Entry points**: `core/apt/build.sh` — action-web-server's `BUILD_COMMAND`, run under `sh` in the workspace after it writes `.env` from SSM; `action.yml` validates the inputs first

## Commands
| Command | Description |
|---------|-------------|
| `make test` | Run BATS tests |
| `make lint` | Run shellcheck on all shell scripts |

## Key files
| File | Purpose |
|------|---------|
| `action.yml` | Composite action definition (inputs, validation, nested `heronlabs/action-web-server@v1`) |
| `core/apt/build.sh` | Release `.deb` + bucket pool -> signed apt repository in `.apt-repository/` |
| `tests/apt.bats` | BATS tests for `core/apt/build.sh` |
| `tests/__mocks__/gh` | gh stub (asserts `--repo`, `--pattern` and the token, copies release assets) |
| `tests/__mocks__/aws` | AWS CLI stub (records invocations, seeds the pool on `s3 sync`) |
| `tests/__mocks__/sudo` | sudo stub (records argv, then runs it) |
| `Makefile` | Test + lint targets |
| `version.txt` | Current semver version |
| `CHANGELOG.md` | Release history |
