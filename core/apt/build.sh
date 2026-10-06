#!/bin/sh
# Builds and signs the apt repository in .apt-repository/ with the .deb of the
# release APT_REPOSITORY_TAG, as the BUILD_COMMAND of heronlabs/action-web-server,
# which writes ./.env (APT_GPG_PRIVATE_KEY among the parameters under
# AWS_ENV_PATH) and publishes .apt-repository/ to APT_REPOSITORY_BUCKET_NAME.
set -eu

: "${APT_REPOSITORY_PACKAGE:?APT_REPOSITORY_PACKAGE is required}"
: "${APT_REPOSITORY_TAG:?APT_REPOSITORY_TAG is required}"
: "${APT_REPOSITORY_ARCHITECTURE:?APT_REPOSITORY_ARCHITECTURE is required}"
: "${APT_REPOSITORY_SUITE:?APT_REPOSITORY_SUITE is required}"
: "${APT_REPOSITORY_COMPONENT:?APT_REPOSITORY_COMPONENT is required}"
: "${APT_REPOSITORY_ORIGIN:?APT_REPOSITORY_ORIGIN is required}"
: "${APT_REPOSITORY_LABEL:?APT_REPOSITORY_LABEL is required}"
: "${APT_REPOSITORY_BUCKET_NAME:?APT_REPOSITORY_BUCKET_NAME is required}"
: "${APT_REPOSITORY_GH_TOKEN:?APT_REPOSITORY_GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

package=$APT_REPOSITORY_PACKAGE
arch=$APT_REPOSITORY_ARCHITECTURE
suite=$APT_REPOSITORY_SUITE
component=$APT_REPOSITORY_COMPONENT
pattern="${package}_*_${arch}.deb"

# Debian pool convention: the first letter, or the first four for lib* packages.
case $package in
  lib*) prefix=$(printf '%s' "$package" | cut -c1-4) ;;
  *) prefix=$(printf '%s' "$package" | cut -c1) ;;
esac

repo=.apt-repository
dist=dists/$suite
index=$dist/$component/binary-$arch
pool=pool/$component/$prefix/$package

if [ ! -f ./.env ]; then
  echo ".env not found in $(pwd): action-web-server writes it from AWS_ENV_PATH" >&2
  exit 1
fi

# No `set -a`: only this shell needs the key, not the processes it starts.
# shellcheck source=/dev/null
. ./.env

if [ -z "${APT_GPG_PRIVATE_KEY:-}" ]; then
  echo "APT_GPG_PRIVATE_KEY is missing from .env: store the armored signing key in the SSM parameter <AWS_ENV_PATH>APT_GPG_PRIVATE_KEY" >&2
  exit 1
fi

# Both temp dirs are absolute (mktemp), so the trap still finds them after the
# `cd` below. The agent is stopped first, or it would outlive its home.
download=""
GNUPGHOME=""
cleanup() {
  if [ -n "$GNUPGHOME" ]; then
    gpgconf --kill gpg-agent >/dev/null 2>&1 || :
    rm -rf "$GNUPGHOME"
  fi
  if [ -n "$download" ]; then
    rm -rf "$download"
  fi
}
trap cleanup EXIT

download=$(mktemp -d)

# --repo: the caller needs no checkout. gh reads the token from GH_TOKEN, so it
# never reaches argv.
GH_TOKEN=$APT_REPOSITORY_GH_TOKEN gh release download "$APT_REPOSITORY_TAG" \
  --repo "$GITHUB_REPOSITORY" --pattern "$pattern" --dir "$download"

set -- "$download"/*.deb
if [ ! -f "$1" ]; then
  echo "release '$APT_REPOSITORY_TAG' of $GITHUB_REPOSITORY has no asset matching '$pattern'" >&2
  exit 1
fi

# The index lists every published version, and action-web-server prunes
# whatever .apt-repository/ does not hold.
aws s3 sync "s3://$APT_REPOSITORY_BUCKET_NAME/pool" "$repo/pool"

if ! command -v apt-ftparchive >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends apt-utils
fi

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
printf '%s\n' "$APT_GPG_PRIVATE_KEY" | gpg --batch --import

# dists/ is regenerated from scratch: a leftover InRelease or Release.gpg from
# an earlier run in the same directory would otherwise be listed in Release.
rm -rf "$repo/dists"
mkdir -p "$repo/$pool" "$repo/$index"
cp "$@" "$repo/$pool/"
cd "$repo"

apt-ftparchive --arch "$arch" packages pool > "$index/Packages"
gzip -9 -n -c "$index/Packages" > "$index/Packages.gz"

# Written outside the suite, so Release does not list itself.
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="$APT_REPOSITORY_ORIGIN" \
  -o APT::FTPArchive::Release::Label="$APT_REPOSITORY_LABEL" \
  -o APT::FTPArchive::Release::Suite="$suite" \
  -o APT::FTPArchive::Release::Codename="$suite" \
  -o APT::FTPArchive::Release::Architectures="$arch" \
  -o APT::FTPArchive::Release::Components="$component" \
  release "$dist" > Release
mv Release "$dist/Release"

gpg --batch --yes --clearsign --output "$dist/InRelease" "$dist/Release"
gpg --batch --yes --armor --detach-sign --output "$dist/Release.gpg" "$dist/Release"
# Binary keyring, the format apt's signed-by expects.
gpg --batch --yes --output "$package.gpg" --export
