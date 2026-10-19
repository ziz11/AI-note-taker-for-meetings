#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h}"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/recordly-app-icon.XXXXXX")"
output_directory="${temporary_root}/AppIcon.appiconset"

cleanup() {
    rm -rf "${temporary_root}"
}
trap cleanup EXIT

mkdir -p "${output_directory}"
swift "${repository_root}/scripts/generate-app-icon.swift" "${output_directory}"

typeset -A expected_sizes=(
    icon_16x16.png 16
    icon_16x16@2x.png 32
    icon_32x32.png 32
    icon_32x32@2x.png 64
    icon_128x128.png 128
    icon_128x128@2x.png 256
    icon_256x256.png 256
    icon_256x256@2x.png 512
    icon_512x512.png 512
    icon_512x512@2x.png 1024
)

for file_name expected_size in ${(kv)expected_sizes}; do
    file_path="${output_directory}/${file_name}"
    [[ -f "${file_path}" ]] || {
        print -u2 "Missing generated icon: ${file_name}"
        exit 1
    }

    actual_width="$(sips -g pixelWidth "${file_path}" | awk '/pixelWidth/ { print $2 }')"
    actual_height="$(sips -g pixelHeight "${file_path}" | awk '/pixelHeight/ { print $2 }')"
    [[ "${actual_width}" == "${expected_size}" && "${actual_height}" == "${expected_size}" ]] || {
        print -u2 "Wrong dimensions for ${file_name}: ${actual_width}x${actual_height}"
        exit 1
    }
done

print "App icon generator smoke test passed."
