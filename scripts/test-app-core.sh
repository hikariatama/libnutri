#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../app" && pwd)
scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/nutrition-core-tests.XXXXXX")
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM
developer_dir=$(xcode-select -p)
testing_plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$testing_plugin" ]; then
    swift test --package-path "$project_dir/ClientCore" --scratch-path "$scratch_dir" \
        -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin" \
        -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/Frameworks" \
        -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib"
else
    swift test --package-path "$project_dir/ClientCore" --scratch-path "$scratch_dir"
fi
