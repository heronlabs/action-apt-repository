# 📦 action-apt-repository — Build, sign and publish a Debian apt repository

[![CI][ci-badge]][ci-url]
[![License: MIT][license-badge]][license-url]

> **GitHub Action** to build and sign a Debian apt repository from a release's `.deb` and publish it through [`heronlabs/action-web-server`](https://github.com/heronlabs/action-web-server).

Downloads `<PACKAGE>_<version>_<ARCHITECTURE>.deb` from a release of the calling repository, adds it to the pool already published in the bucket, regenerates the `Packages` index and the `Release` file, signs them with a key read from SSM Parameter Store, and hands the result to `heronlabs/action-web-server@v1`, which publishes it to S3 with cache-aware grace pruning and invalidates CloudFront. The caller sets no `BUILD_COMMAND`, `BUILD_FOLDER` or `NO_CACHE_PATTERNS`.

## Contents

- [Usage](#usage)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Permissions](#permissions)
- [Signing key](#signing-key)
- [Client setup](#client-setup)
- [Repository layout](#repository-layout)
- [Architecture](#architecture)
- [How it works](#how-it-works)
- [Notes](#notes)
- [License](#license)

## Usage

```yaml
name: Release

on:
  push:
    branches: [main]

jobs:
  release:
    runs-on: ubuntu-24.04
    outputs:
      tag: ${{ steps.release.outputs.tag }}
    steps:
      - id: release
        # ... builds my-package_<version>_amd64.deb, attaches it to a release
        # and sets the `tag` output
        run: echo "tag=v1.2.3" >> "$GITHUB_OUTPUT"

  apt:
    needs: release
    runs-on: ubuntu-24.04
    environment: production
    permissions:
      id-token: write
      contents: read
    steps:
      - name: Publish apt repository
        uses: heronlabs/action-apt-repository@v1
        with:
          AWS_ROLE_TO_ASSUME: ${{ secrets.AWS_ROLE_ARN }}
          AWS_REGION: us-east-1
          AWS_ENV_PATH: /my-package/apt/
          BUCKET_NAME: apt.example.com
          DISTRIBUTION_ID: E1ABCDEF2GHIJK
          PACKAGE: my-package
          TAG: ${{ needs.release.outputs.tag }}
          ORIGIN: Heron Labs
```

No checkout and no toolchain setup: the `.deb` is downloaded with `gh release download --repo`.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `AWS_ROLE_TO_ASSUME` | ARN of the IAM role to assume via OIDC | Yes | — |
| `AWS_REGION` | AWS region where the S3 bucket and SSM parameters live | Yes | — |
| `AWS_ROLE_DURATION_SECONDS` | Duration in seconds for each assumed role session | No | `900` |
| `AWS_ENV_PATH` | SSM parameter path prefix holding the `APT_GPG_PRIVATE_KEY` parameter (e.g. `/my-package/apt/`) | Yes | — |
| `BUCKET_NAME` | Destination S3 bucket name | Yes | — |
| `DISTRIBUTION_ID` | CloudFront distribution ID to invalidate after publishing | Yes | — |
| `PACKAGE` | Debian package name; must match `^[a-z0-9][a-z0-9.+-]+$` | Yes | — |
| `TAG` | Release of the calling repository that holds `<PACKAGE>_<version>_<ARCHITECTURE>.deb` | Yes | — |
| `ARCHITECTURE` | Debian architecture of the `.deb`; must match `^[a-z0-9-]+$` | No | `amd64` |
| `SUITE` | Suite (and codename) of the repository; must match `^[a-z0-9-]+$` | No | `stable` |
| `COMPONENT` | Component of the repository; must match `^[a-z0-9-]+$` | No | `main` |
| `ORIGIN` | `Origin` field of the `Release` file | Yes | — |
| `LABEL` | `Label` field of the `Release` file | No | `PACKAGE` |
| `GH_TOKEN` | Token used to download the release asset | No | `${{ github.token }}` |

`heronlabs/action-web-server`'s `LEAK_CHECK` and `PRUNE_GRACE_DAYS` keep their defaults (`true`, `7`) and are not exposed.

## Outputs

This action produces no outputs.

## Permissions

```yaml
permissions:
  id-token: write
  contents: read
```

`contents: read` lets the default `GH_TOKEN` download the release asset.

### Minimum IAM policy

The same as `heronlabs/action-web-server`'s: the build reads the published
pool with `aws s3 sync`, which `s3:ListBucket` and `s3:GetObject` already
cover, and `APT_GPG_PRIVATE_KEY` comes from the SSM read that action does.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<bucket-name>"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<bucket-name>/*"
    },
    {
      "Effect": "Allow",
      "Action": ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"],
      "Resource": "arn:aws:cloudfront::<account-id>:distribution/<distribution-id>"
    },
    {
      "Effect": "Allow",
      "Action": "ssm:GetParametersByPath",
      "Resource": "arn:aws:ssm:<region>:<account-id>:parameter<aws-env-path>/*"
    }
  ]
}
```

## Signing key

The repository is signed with an armored OpenPGP private key without a
passphrase, stored as the `SecureString` parameter `APT_GPG_PRIVATE_KEY`
directly under `AWS_ENV_PATH`. Create it in a throwaway `GNUPGHOME`, so the key
never touches your own keyring:

```bash
export GNUPGHOME="$(mktemp -d)"
gpg --batch --passphrase '' --quick-generate-key 'Heron Labs apt <apt@example.com>' ed25519 sign never
gpg --armor --export-secret-keys 'Heron Labs apt <apt@example.com>' > key.asc
aws ssm put-parameter --name /my-package/apt/APT_GPG_PRIVATE_KEY --type SecureString --value file://key.asc
gpgconf --kill gpg-agent
rm -rf "$GNUPGHOME" key.asc
unset GNUPGHOME
```

- **ed25519.** The armored key is about 450 bytes, well inside the 4 KB value
  limit of the SSM standard tier. An RSA 4096 key is already about 3.4 KB, and
  one with an encryption subkey (about 6.6 KB) needs the advanced tier.
- **No expiry (`never`).** An expired key makes apt reject the repository on
  every host that trusts it, until each one downloads a renewed key.
- **Rotation.** Run the same commands with `--overwrite` on
  `aws ssm put-parameter`. The next run signs with the new key and publishes
  the new `<PACKAGE>.gpg`; every host must download it again (see
  [Client setup](#client-setup)), or apt rejects the repository.

## Client setup

The public key is published at the repository root as `<PACKAGE>.gpg`, a
binary keyring for `signed-by`:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/my-package.gpg https://apt.example.com/my-package.gpg
echo 'deb [signed-by=/etc/apt/keyrings/my-package.gpg] https://apt.example.com stable main' \
  | sudo tee /etc/apt/sources.list.d/my-package.list
sudo apt-get update
sudo apt-get install my-package
```

`stable main` is `<SUITE> <COMPONENT>`.

## Repository layout

What `.apt-repository/` (the `BUILD_FOLDER`) holds, published to the bucket root:

```
<PACKAGE>.gpg                                   # public key (binary keyring)          no-cache
dists/<SUITE>/
├── Release                                     # Origin, Label, Suite, Codename, ...  no-cache
├── InRelease                                   # clearsigned Release                  no-cache
├── Release.gpg                                 # armored detached signature           no-cache
└── <COMPONENT>/binary-<ARCHITECTURE>/
    ├── Packages                                # every version in the pool            no-cache
    └── Packages.gz                             #                                      no-cache
pool/<COMPONENT>/<prefix>/<PACKAGE>/
└── <PACKAGE>_<version>_<ARCHITECTURE>.deb      # one per release                      immutable, one year
```

`<prefix>` follows the Debian convention: the first letter of `PACKAGE`, or
the first four letters for `lib*` packages (`pool/main/libf/libfoo/`).

## Architecture

POSIX shell script run by a composite GitHub Action that wraps `heronlabs/action-web-server@v1`.

```
├── action.yml                    # Composite action definition (inputs, validation, nested action)
├── core/
│   └── apt/
│       └── build.sh              # Release .deb + bucket pool -> signed apt repository
├── tests/
│   ├── __mocks__/
│   │   ├── aws                   # AWS CLI stub (records invocations, seeds the pool)
│   │   ├── gh                    # gh stub (asserts --repo and --pattern, copies release assets)
│   │   └── sudo                  # sudo stub (records argv, then runs it)
│   └── apt.bats                  # BATS tests — core/apt/build.sh
├── Makefile                      # test (bats) + lint (shellcheck)
└── version.txt                   # Current version
```

## How it works

`action.yml` defines two composite steps:

1. **Validate inputs** — fails fast when `PACKAGE`, `ARCHITECTURE`, `SUITE` or `COMPONENT` does not match its pattern, or `TAG` is empty. The inputs reach the script through `env:`, never interpolated into it.
2. **Build and publish** — `heronlabs/action-web-server@v1` with `BUILD_COMMAND: sh "${{ github.action_path }}/core/apt/build.sh"`, `BUILD_FOLDER: .apt-repository` and `NO_CACHE_PATTERNS: 'dists/*,*.gpg'`. It assumes the OIDC role, writes every parameter under `AWS_ENV_PATH` to `.env`, runs the build, checks `.apt-repository/` for leaked `SecureString` values, publishes it with grace pruning and invalidates CloudFront.

`core/apt/build.sh` runs in the workspace, where `.env` was written:

1. **Signing key** — sources `./.env` for `APT_GPG_PRIVATE_KEY`, without `set -a`: the key never enters the environment of a child process nor any command line; gpg reads it from a pipe.
2. **Download** — `gh release download "$TAG" --repo "$GITHUB_REPOSITORY" --pattern '<PACKAGE>_*_<ARCHITECTURE>.deb'` into a temporary directory, with the token in `GH_TOKEN`, never on the command line. Nothing downloaded fails the build.
3. **Pool** — `aws s3 sync "s3://<BUCKET_NAME>/pool" .apt-repository/pool`. The index must list every published version, and action-web-server prunes whatever `.apt-repository/` does not hold.
4. **Tooling** — installs `apt-utils` with `sudo apt-get` when `apt-ftparchive` is missing.
5. **Import** — `printf '%s\n' "$APT_GPG_PRIVATE_KEY" | gpg --batch --import` into a temporary `GNUPGHOME`; an `EXIT` trap stops its agent and removes it.
6. **Index** — copies the `.deb` to `pool/<COMPONENT>/<prefix>/<PACKAGE>/`, then `apt-ftparchive --arch <ARCHITECTURE> packages pool` writes `Packages` and `gzip -9 -n` writes `Packages.gz`. `dists/` is regenerated from scratch on every run.
7. **Release** — `apt-ftparchive release` with `Origin`, `Label`, `Suite`, `Codename` (= `SUITE`), `Architectures` and `Components`, written outside the suite and moved in, so it does not list itself.
8. **Sign** — clearsigns `Release` to `InRelease`, detach-signs it to `Release.gpg`, and exports the public key to `<PACKAGE>.gpg`.

Two runner behaviours make the nesting work (actions/runner at [`67f01c2`](https://github.com/actions/runner/tree/67f01c276e0a91d967ba499ce4cdc9a95efa0262)):

- `${{ github.action_path }}` in the `with:` of the nested `uses:` step is **this** action's directory: [`CompositeActionHandler.cs#L161`](https://github.com/actions/runner/blob/67f01c276e0a91d967ba499ce4cdc9a95efa0262/src/Runner.Worker/Handlers/CompositeActionHandler.cs#L161) sets `action_path` on each embedded step's github context to the containing composite's directory, and [`ActionRunner.cs#L184`](https://github.com/actions/runner/blob/67f01c276e0a91d967ba499ce4cdc9a95efa0262/src/Runner.Worker/ActionRunner.cs#L184) evaluates that step's `with:` in that context.
- The `env:` of the nested `uses:` step reaches every step of action-web-server, its Build step included: [`CompositeActionHandler.cs#L260-L295`](https://github.com/actions/runner/blob/67f01c276e0a91d967ba499ce4cdc9a95efa0262/src/Runner.Worker/Handlers/CompositeActionHandler.cs#L260-L295) merges the step's env into every embedded step of the nested composite. That is how the `APT_REPOSITORY_*` variables reach `build.sh`.

## Notes

- **Requires `heronlabs/action-web-server` ≥ v1.0.3.** Its leak check matches a multi-line value (the armored key) line by line since [heronlabs/action-web-server#5](https://github.com/heronlabs/action-web-server/pull/5); before that, the blank line of the armor failed every build. `@v1` resolves to it.
- **Cache strategy.** `dists/*` and `*.gpg` are published with `cache-control no-cache` (`aws s3` patterns match across `/`, so `*.gpg` covers both `<PACKAGE>.gpg` and `dists/<SUITE>/Release.gpg`); the `.deb`s under `pool/` keep the one-year immutable cache, so a published version must never be rebuilt with different content.
- **One bucket per repository, one `ARCHITECTURE`, `SUITE` and `COMPONENT` per bucket.** action-web-server prunes whatever the build does not hold, and `dists/` is regenerated from this run's inputs only.
- **Runner tools.** `gh`, `gpg`, `aws` and `node` (action-web-server reads SSM through `npx`) must be on `PATH`, as they are on GitHub-hosted Ubuntu runners; `apt-ftparchive` is installed when missing, which needs passwordless `sudo`.
- Requires an OIDC trust relationship configured on the AWS account.

## License

MIT

[ci-badge]: https://github.com/heronlabs/action-apt-repository/actions/workflows/continuous-integration.yml/badge.svg
[ci-url]: https://github.com/heronlabs/action-apt-repository/actions/workflows/continuous-integration.yml
[license-badge]: https://img.shields.io/badge/License-MIT-blue.svg
[license-url]: ./LICENSE
