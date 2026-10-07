#!/usr/bin/env bash
# Builds a CurseForge-ready zip containing only the addon code.
# Usage: ./package.sh [version]   (defaults to the ## Version in the TOC)
set -euo pipefail

cd "$(dirname "$0")"

ADDON="PeggleForever"
TOC_VERSION="$(sed -n 's/^## Version:[[:space:]]*//p' "$ADDON.toc" | tr -d '\r')"
VERSION="${1:-$TOC_VERSION}"
RELEASE_DIR=".release"
STAGE="$RELEASE_DIR/$ADDON"
ZIP="$RELEASE_DIR/$ADDON-$VERSION.zip"

rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"

cp Compat.lua Peggle.lua "$STAGE/"
cp -r images sounds "$STAGE/"
# readme.txt is PopCap's copyright notice and third-party licences; keep it with the code.
cp readme.txt changelog.txt "$STAGE/"
sed -e "s/^## Version:.*/## Version: $VERSION/" -e "s/@project-version@/$VERSION/g" "$ADDON.toc" > "$STAGE/$ADDON.toc"

(cd "$RELEASE_DIR" && zip -rq "$(basename "$ZIP")" "$ADDON")
rm -rf "$STAGE"

echo "Created $ZIP"
