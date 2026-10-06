#!/usr/bin/env bats
# bats tests for core/apt/build.sh
#
# Builds tiny fixture .debs and a signing key once per file, then runs the script
# under `sh` in a throwaway workspace with `gh`, `aws` and `sudo` stubs on PATH
# and asserts on the exit code, the stub logs and the repository it leaves in
# .apt-repository/. The real gpg, gpgv, apt-ftparchive and dpkg-deb do the work,
# so the tests skip where they are missing (macOS); CI installs them.
# No network, no real GitHub or AWS.

setup_file() {
  APT_TOOLS_MISSING=""
  local tool
  for tool in gpg gpgv gpgconf apt-ftparchive dpkg-deb; do
    command -v "$tool" >/dev/null || APT_TOOLS_MISSING="$APT_TOOLS_MISSING $tool"
  done
  export APT_TOOLS_MISSING
  [ -z "$APT_TOOLS_MISSING" ] || return 0

  APT_FTPARCHIVE_BIN="$(command -v apt-ftparchive)"
  FIXTURES="$(mktemp -d)"
  export APT_FTPARCHIVE_BIN FIXTURES

  build_deb hello 1.0.0
  build_deb hello 1.1.0
  build_deb hello 1.0.0 arm64
  build_deb libhello 1.0.0

  generate_key signer 'Apt Signer <signer@example.com>'
  generate_key caller 'Caller <caller@example.com>'
  SIGNER_FPR="$(GNUPGHOME="$FIXTURES/signer" gpg --batch --with-colons --list-keys | awk -F: '/^fpr/ {print $10; exit}')"
  export SIGNER_FPR
}

teardown_file() {
  [ -n "${FIXTURES:-}" ] || return 0
  rm -rf "$FIXTURES"
}

# build_deb NAME VERSION [ARCH] -> $FIXTURES/NAME_VERSION_ARCH.deb (ARCH defaults to amd64)
# apt-ftparchive --arch filters on the control Architecture, so it must match.
build_deb() {
  local arch="${3:-amd64}" root; root="$(mktemp -d)"
  chmod 755 "$root"
  mkdir -p "$root/DEBIAN"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Heron Labs <devops@example.com>\nDescription: action-apt-repository test fixture\n' \
    "$1" "$2" "$arch" >"$root/DEBIAN/control"
  dpkg-deb --root-owner-group --build "$root" "$FIXTURES/$1_$2_$arch.deb" >/dev/null
  rm -rf "$root"
}

# generate_key NAME UID -> keyring $FIXTURES/NAME, armored secret key $FIXTURES/NAME.asc
# ed25519, no passphrase, no expiry: the key the README tells callers to create.
generate_key() {
  local home="$FIXTURES/$1"
  mkdir -m 700 "$home"
  GNUPGHOME="$home" gpg --batch --passphrase '' --quick-generate-key "$2" ed25519 sign never 2>/dev/null
  GNUPGHOME="$home" gpg --batch --armor --export-secret-keys "$2" >"$home.asc"
  GNUPGHOME="$home" gpgconf --kill gpg-agent
}

setup() {
  if [ -n "$APT_TOOLS_MISSING" ]; then
    skip "needs$APT_TOOLS_MISSING (CI installs them)"
  fi

  SCRIPT="$BATS_TEST_DIRNAME/../core/apt/build.sh"
  STUB_DIR="$BATS_TEST_DIRNAME/__mocks__"   # contains the `gh`, `aws` and `sudo` stubs
  SH_BIN="$(command -v sh)"
  SANDBOX="$(mktemp -d)"
  WORK="$SANDBOX/work"                      # the runner workspace: .env and .apt-repository
  REPO="$WORK/.apt-repository"
  RELEASE_DIR="$SANDBOX/release"            # assets of the GitHub release
  POOL_DIR="$SANDBOX/bucket-pool"           # s3://BUCKET/pool; absent = empty pool
  BIN_DIR="$SANDBOX/bin"                    # fake apt-get
  mkdir "$WORK" "$RELEASE_DIR" "$BIN_DIR" "$SANDBOX/tmp" "$SANDBOX/gnupg"
  chmod 700 "$SANDBOX/gnupg"
  GH_LOG="$SANDBOX/gh.log"; : >"$GH_LOG"
  AWS_LOG="$SANDBOX/aws.log"; : >"$AWS_LOG"
  SUDO_LOG="$SANDBOX/sudo.log"; : >"$SUDO_LOG"

  # The .env action-web-server writes: one NAME='value' per SSM parameter.
  printf "APT_GPG_PRIVATE_KEY='%s'\nOTHER_PARAMETER='value'\n" "$(cat "$FIXTURES/signer.asc")" >"$WORK/.env"

  # Fake apt-get, reached through the sudo stub: `install` puts the real
  # apt-ftparchive on PATH, as installing apt-utils would.
  cat >"$BIN_DIR/apt-get" <<STUB
#!/usr/bin/env bash
if [ "\$1" = install ]; then ln -s "$APT_FTPARCHIVE_BIN" "$BIN_DIR/apt-ftparchive"; fi
STUB
  chmod +x "$BIN_DIR/apt-get"
}

teardown() {
  [ -n "${SANDBOX:-}" ] || return 0
  rm -rf "$SANDBOX"
}

# attach NAME VERSION: the release holds NAME_VERSION_amd64.deb
attach() { cp "$FIXTURES/$1_$2_amd64.deb" "$RELEASE_DIR/"; }

# seed_pool NAME VERSION [ARCH]: the bucket's pool already holds NAME_VERSION_ARCH.deb
seed_pool() {
  local prefix="${1:0:1}"
  case "$1" in lib*) prefix="${1:0:4}" ;; esac
  mkdir -p "$POOL_DIR/main/$prefix/$1"
  cp "$FIXTURES/$1_$2_${3:-amd64}.deb" "$POOL_DIR/main/$prefix/$1/"
}

# Run core/apt/build.sh under sh inside the workspace with the stubs on PATH.
# Usage: run_build [VAR=value ...]  (later assignments override the defaults)
# Sets EXIT_CODE; stdout/stderr land in $SANDBOX/stdout and $SANDBOX/stderr.
run_build() {
  set +e
  ( cd "$WORK" \
    && env PATH="$STUB_DIR:$BIN_DIR:$PATH" TMPDIR="$SANDBOX/tmp" \
      GH_LOG="$GH_LOG" GH_RELEASE_DIR="$RELEASE_DIR" GH_EXPECT_REPO=heronlabs/hello \
      GH_EXPECT_PATTERN='hello_*_amd64.deb' GH_EXPECT_TOKEN=gh-token-fixture \
      AWS_LOG="$AWS_LOG" AWS_POOL_DIR="$POOL_DIR" SUDO_LOG="$SUDO_LOG" \
      GITHUB_REPOSITORY=heronlabs/hello \
      APT_REPOSITORY_PACKAGE=hello APT_REPOSITORY_TAG=v1.1.0 \
      APT_REPOSITORY_ARCHITECTURE=amd64 APT_REPOSITORY_SUITE=stable APT_REPOSITORY_COMPONENT=main \
      APT_REPOSITORY_ORIGIN='Heron Labs' APT_REPOSITORY_LABEL=hello \
      APT_REPOSITORY_BUCKET_NAME=apt-bucket APT_REPOSITORY_GH_TOKEN=gh-token-fixture \
      "$@" \
      "$SH_BIN" "$SCRIPT" >"$SANDBOX/stdout" 2>"$SANDBOX/stderr" )
  EXIT_CODE=$?
  set -e
}

# ---------------------------------------------------------------- tests

@test "first release: builds the full layout from an empty pool" {
  attach hello 1.1.0

  run_build

  [ "$EXIT_CODE" -eq 0 ]
  [ -f "$REPO/hello.gpg" ]
  [ -f "$REPO/dists/stable/Release" ]
  [ -f "$REPO/dists/stable/InRelease" ]
  [ -f "$REPO/dists/stable/Release.gpg" ]
  [ -f "$REPO/dists/stable/main/binary-amd64/Packages" ]
  [ "$(gzip -dc "$REPO/dists/stable/main/binary-amd64/Packages.gz")" = "$(cat "$REPO/dists/stable/main/binary-amd64/Packages")" ]
  [ -f "$REPO/pool/main/h/hello/hello_1.1.0_amd64.deb" ]
  grep -qxF 'Filename: pool/main/h/hello/hello_1.1.0_amd64.deb' "$REPO/dists/stable/main/binary-amd64/Packages"
  grep -qF -- "gh release download v1.1.0 --repo heronlabs/hello --pattern hello_*_amd64.deb --dir " "$GH_LOG"
  [ "$(cat "$AWS_LOG")" = "aws s3 sync s3://apt-bucket/pool .apt-repository/pool" ]
}

@test "existing pool: Packages lists the seeded version and the new one" {
  seed_pool hello 1.0.0
  attach hello 1.1.0

  run_build

  [ "$EXIT_CODE" -eq 0 ]
  local packages="$REPO/dists/stable/main/binary-amd64/Packages"
  [ "$(grep -c '^Package: hello$' "$packages")" -eq 2 ]
  grep -qxF 'Version: 1.0.0' "$packages"
  grep -qxF 'Version: 1.1.0' "$packages"
  grep -qxF 'Filename: pool/main/h/hello/hello_1.0.0_amd64.deb' "$packages"
  grep -qxF 'Filename: pool/main/h/hello/hello_1.1.0_amd64.deb' "$packages"
}

@test "existing pool: a .deb of another architecture stays out of Packages" {
  seed_pool hello 1.0.0 arm64
  attach hello 1.1.0

  run_build

  [ "$EXIT_CODE" -eq 0 ]
  local packages="$REPO/dists/stable/main/binary-amd64/Packages"
  [ "$(grep -c '^Package: hello$' "$packages")" -eq 1 ]
  grep -qxF 'Filename: pool/main/h/hello/hello_1.1.0_amd64.deb' "$packages"
  [ "$(grep -c 'arm64' "$packages")" -eq 0 ]
}

@test "Release: Origin, Label, Suite, Codename, Architectures and Components come from the inputs" {
  attach hello 1.1.0

  run_build APT_REPOSITORY_SUITE=edge APT_REPOSITORY_COMPONENT=contrib \
    APT_REPOSITORY_ORIGIN='Example Org' APT_REPOSITORY_LABEL='Hello Tools'

  [ "$EXIT_CODE" -eq 0 ]
  local release="$REPO/dists/edge/Release"
  grep -qxF 'Origin: Example Org' "$release"
  grep -qxF 'Label: Hello Tools' "$release"
  grep -qxF 'Suite: edge' "$release"
  grep -qxF 'Codename: edge' "$release"
  grep -qxF 'Architectures: amd64' "$release"
  grep -qxF 'Components: contrib' "$release"
  [ -f "$REPO/dists/edge/contrib/binary-amd64/Packages" ]
  [ -f "$REPO/pool/contrib/h/hello/hello_1.1.0_amd64.deb" ]
}

# A second run in the same workspace finds the InRelease and Release.gpg of the
# first one in dists/: they must not end up listed in the new Release.
@test "Release: does not list Release, InRelease or Release.gpg, even on a second run" {
  attach hello 1.1.0

  run_build
  [ "$EXIT_CODE" -eq 0 ]
  run_build
  [ "$EXIT_CODE" -eq 0 ]

  local release="$REPO/dists/stable/Release"
  awk '/^ / {print $3}' "$release" >"$SANDBOX/listed"
  grep -qxF 'main/binary-amd64/Packages' "$SANDBOX/listed"
  [ "$(grep -cxE '(In)?Release|Release\.gpg' "$SANDBOX/listed")" -eq 0 ]
}

@test "signatures: InRelease and Release.gpg verify with gpgv --keyring <PACKAGE>.gpg" {
  attach hello 1.1.0

  run_build

  [ "$EXIT_CODE" -eq 0 ]
  local dist="$REPO/dists/stable"
  gpgv --status-fd 1 --keyring "$REPO/hello.gpg" "$dist/InRelease" 2>/dev/null \
    | grep -q "^\[GNUPG:\] VALIDSIG $SIGNER_FPR "
  gpgv --status-fd 1 --keyring "$REPO/hello.gpg" "$dist/Release.gpg" "$dist/Release" 2>/dev/null \
    | grep -q "^\[GNUPG:\] VALIDSIG $SIGNER_FPR "
}

@test "public key: <PACKAGE>.gpg holds only the signing key when the caller's GNUPGHOME has another key" {
  attach hello 1.1.0

  run_build GNUPGHOME="$FIXTURES/caller"

  [ "$EXIT_CODE" -eq 0 ]
  # Binary keyring (signed-by), not armored.
  [ "$(head -c 5 "$REPO/hello.gpg")" != "-----" ]
  [ "$(GNUPGHOME="$SANDBOX/gnupg" gpg --batch --with-colons --show-keys "$REPO/hello.gpg" 2>/dev/null \
    | awk -F: '/^fpr/ {print $10}')" = "$SIGNER_FPR" ]
  # The signing key never reaches the caller's keyring.
  [ "$(GNUPGHOME="$FIXTURES/caller" gpg --batch --with-colons --list-keys 2>/dev/null | grep -c "$SIGNER_FPR")" -eq 0 ]
}

@test "cleanup: the temporary GNUPGHOME and download dir are gone after the run" {
  attach hello 1.1.0

  run_build

  [ "$EXIT_CODE" -eq 0 ]
  grep -qF -- "--dir $SANDBOX/tmp/" "$GH_LOG"
  [ -z "$(ls -A "$SANDBOX/tmp")" ]
}

@test "cleanup: an unusable key fails the build and still removes the temporary GNUPGHOME" {
  attach hello 1.1.0
  printf "APT_GPG_PRIVATE_KEY='not a key'\n" >"$WORK/.env"

  run_build

  [ "$EXIT_CODE" -ne 0 ]
  [ ! -e "$REPO/dists" ]
  [ -z "$(ls -A "$SANDBOX/tmp")" ]
}

@test "apt-ftparchive present: sudo never runs" {
  attach hello 1.1.0

  run_build

  [ "$EXIT_CODE" -eq 0 ]
  [ ! -s "$SUDO_LOG" ]
  [ ! -e "$BIN_DIR/apt-ftparchive" ]
}

@test "apt-ftparchive missing: installs apt-utils through sudo, then builds" {
  attach hello 1.1.0
  # Only what the script and the stubs run, without apt-ftparchive.
  local restricted="$SANDBOX/restricted" tool
  mkdir "$restricted"
  for tool in bash cat cp cut env gpg gpgconf gzip ln mkdir mktemp mv rm; do
    ln -s "$(command -v "$tool")" "$restricted/$tool"
  done
  [ -z "$(PATH="$STUB_DIR:$BIN_DIR:$restricted" command -v apt-ftparchive)" ]

  run_build PATH="$STUB_DIR:$BIN_DIR:$restricted"

  [ "$EXIT_CODE" -eq 0 ]
  [ "$(sed -n 1p "$SUDO_LOG")" = "sudo apt-get update" ]
  [ "$(sed -n 2p "$SUDO_LOG")" = "sudo apt-get install -y --no-install-recommends apt-utils" ]
  [ "$(wc -l <"$SUDO_LOG")" -eq 2 ]
  [ -f "$REPO/dists/stable/main/binary-amd64/Packages" ]
}

@test "lib* package: the pool prefix is the first four letters" {
  attach libhello 1.0.0

  run_build APT_REPOSITORY_PACKAGE=libhello APT_REPOSITORY_LABEL=libhello GH_EXPECT_PATTERN='libhello_*_amd64.deb'

  [ "$EXIT_CODE" -eq 0 ]
  [ -f "$REPO/pool/main/libh/libhello/libhello_1.0.0_amd64.deb" ]
  grep -qxF 'Filename: pool/main/libh/libhello/libhello_1.0.0_amd64.deb' "$REPO/dists/stable/main/binary-amd64/Packages"
  [ -f "$REPO/libhello.gpg" ]
}

@test "GH_TOKEN: reaches gh through the environment, never argv" {
  attach hello 1.1.0

  run_build

  [ "$EXIT_CODE" -eq 0 ]
  [ "$(grep -c 'gh-token-fixture' "$GH_LOG")" -eq 0 ]
}

# Mirrors action-web-server's leak check (grep -rlF -f, lines of 16+ characters),
# which scans .apt-repository/ for APT_GPG_PRIVATE_KEY before publishing.
@test "leak: no line of the armored private key reaches .apt-repository" {
  seed_pool hello 1.0.0
  attach hello 1.1.0

  run_build

  [ "$EXIT_CODE" -eq 0 ]
  local line
  while IFS= read -r line; do
    if [ "${#line}" -ge 16 ]; then
      printf '%s\n' "$line"
    fi
  done <"$FIXTURES/signer.asc" >"$SANDBOX/needle"
  [ -s "$SANDBOX/needle" ]
  run grep -rlF -f "$SANDBOX/needle" -- "$REPO"
  [ "$status" -eq 1 ]
}

@test "no matching .deb: fails with a clear message, nothing synced or built" {
  cp "$FIXTURES/hello_1.1.0_amd64.deb" "$RELEASE_DIR/hello_1.1.0_arm64.deb"

  run_build

  [ "$EXIT_CODE" -ne 0 ]
  grep -qF "release 'v1.1.0' of heronlabs/hello has no asset matching 'hello_*_amd64.deb'" "$SANDBOX/stderr"
  [ ! -s "$AWS_LOG" ]
  [ ! -e "$REPO" ]
}

@test "missing APT_GPG_PRIVATE_KEY: fails with a clear message before any download" {
  attach hello 1.1.0
  printf "OTHER_PARAMETER='value'\n" >"$WORK/.env"

  run_build

  [ "$EXIT_CODE" -ne 0 ]
  grep -qF "APT_GPG_PRIVATE_KEY is missing from .env" "$SANDBOX/stderr"
  [ ! -s "$GH_LOG" ]
  [ ! -e "$REPO" ]
}

@test "missing .env: fails with a clear message before any download" {
  attach hello 1.1.0
  rm "$WORK/.env"

  run_build

  [ "$EXIT_CODE" -ne 0 ]
  grep -qF ".env not found" "$SANDBOX/stderr"
  [ ! -s "$GH_LOG" ]
}

@test "missing input: fails with a clear message before any download" {
  attach hello 1.1.0

  run_build APT_REPOSITORY_TAG=

  [ "$EXIT_CODE" -ne 0 ]
  grep -qF "APT_REPOSITORY_TAG is required" "$SANDBOX/stderr"
  [ ! -s "$GH_LOG" ]
}
