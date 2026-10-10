#!/usr/bin/env bash
# Vendor the CVFPU subset the build uses (the files src/cvfpu_sources.f names, the include
# directory, the licences) into third_party/cvfpu from a checkout of tommythorn/cvfpu at one
# commit. third_party/cvfpu/UPSTREAM records what was imported; the directory is regenerated
# whole, so an upstream update is one run of this script and one commit.
#   tools/cvfpu-import.sh <commit>                 # clones the fork, with its submodules
#   SRC=<checkout> tools/cvfpu-import.sh <commit>  # from a checkout already at <commit>
set -eu
cd "$(dirname "$0")/.."
COMMIT=${1:?upstream commit}
URL=https://github.com/tommythorn/cvfpu.git
if [ -z "${SRC:-}" ]; then
   SRC=$(mktemp -d); trap 'rm -rf "$SRC"' EXIT
   git clone -q "$URL" "$SRC"
   git -C "$SRC" checkout -q "$COMMIT"
   git -C "$SRC" submodule update -q --init --recursive
fi
HAVE=$(git -C "$SRC" rev-parse HEAD)
case "$HAVE" in "$COMMIT"*) ;; *) echo "SRC is at $HAVE, not $COMMIT" >&2; exit 1;; esac
rm -rf third_party/cvfpu
sed -n 's#^\.\./third_party/cvfpu/##p' src/cvfpu_sources.f | while read -r f; do
   mkdir -p "third_party/cvfpu/$(dirname "$f")"
   cp "$SRC/$f" "third_party/cvfpu/$f"
done
mkdir -p third_party/cvfpu/src/common_cells
cp -r "$SRC/src/common_cells/include" third_party/cvfpu/src/common_cells/
for l in LICENSE.solderpad LICENSE.apache src/common_cells/LICENSE vendor/cvw/LICENSE \
         vendor/opene906/LICENSE vendor/openc910/LICENSE; do
   if [ -f "$SRC/$l" ]; then mkdir -p "third_party/cvfpu/$(dirname "$l")"; cp "$SRC/$l" "third_party/cvfpu/$l"; fi
done
{ echo "$URL"; echo "$HAVE"; git -C "$SRC" log -1 --format='%cd %s' --date=short; } > third_party/cvfpu/UPSTREAM
echo "third_party/cvfpu: $(find third_party/cvfpu -type f | wc -l) files from $URL @ ${HAVE:0:9}"
