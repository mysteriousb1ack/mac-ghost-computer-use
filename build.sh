#!/bin/sh
set -eu
cd "$(dirname "$0")"
umask 077
# Keep SwiftPM, clang and compiler temporaries off iCloud-synced paths (e.g. Desktop)
# where SQLite build.db can hit FileProvider disk I/O errors, while allowing override.
if [ -n "${MACGHOST_BUILD_DIR:-}" ]; then
    work="$MACGHOST_BUILD_DIR"
else
    work="$HOME/Library/Caches/mac-ghost-build"
fi
mkdir -p "$work/tmp"
TMPDIR=$(stat -f '/.vol/%d/%i' "$work/tmp")
export TMPDIR
export SQLITE_TMPDIR="$TMPDIR"
export CLANG_MODULE_CACHE_PATH="$work/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$work/modules"
swiftpm() {
    # In an already sandboxed build runner Darwin rejects nested sandbox_apply.
    # This package has no dependencies or build plugins. Normal builds use SwiftPM defaults.
    if [ "${MACGHOST_NESTED_BUILD:-0}" = 1 ]; then set -- "$@" --disable-sandbox; fi
    /usr/bin/swift "$@" --scratch-path "$work" --cache-path "$work/cache" \
        --config-path "$work/config" --security-path "$work/security" \
        --manifest-cache none -debug-info-format none
}
case "${1:-release}" in
    release)
        swiftpm build -c release
        product=$(swiftpm build -c release --show-bin-path)
        mkdir -p bin
        temp=$(mktemp "$PWD/bin/.helper.XXXXXXXX")
        trap 'rm -f "$temp"' EXIT
        install -m 755 "$product/mac-ghost-helper" "$temp"
        mv -f "$temp" bin/mac-ghost-helper
        ;;
    test) swiftpm test ;;
    *) echo 'Usage: ./build.sh [release|test]' >&2; exit 2 ;;
esac
