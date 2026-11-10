# This file is the project's own — add recipes below. Keep the import: it
# mounts every shared limen task under `just do ...`.
import '.limen/just/main.just'

# The FIRST recipe defined here becomes `just`'s default.
lint: do::lint::default
fix: do::fix::default

# Build the package (macOS arm64 only): every source from pins.yaml, verified
# by digest; the result is build/dist/openssh_<version>_darwin_arm64.tar.gz.
# PACKAGE_VERSION=10.6.1.2 names a rebuild; the default is the pinned OpenSSH
# version with its portable level as the third segment. Ad hoc signed unless
# APPLE_SIGN_IDENTITY is exported (the release lane's sign job).
build:
    ./build.sh

# Smoke-test the built package, relocated to a temp dir: version, security
# keys, the shipped config, scp's ssh, the agent through its launch script.
test:
    ./test-binary.sh

# What the Apple release lane's sign job runs (limen's book/releasing.md): the
# package built under the tag's version, signed with the identity the lane
# exports (Developer ID, hardened runtime, timestamped; ad hoc locally),
# smoke-tested relocated, and placed under .build/assets/ with its SBOM, one
# SPDX JSON document per archive by syft from the toolset. The lane hands
# .build/assets/ to its publish job, where goreleaser's before hook runs
# verify-assets. Not notarized: hermetic's download carries no quarantine
# attribute, so Gatekeeper never consults a notarization for these.
[doc('Build, sign, smoke-test and package the version into .build/assets/, with its SBOM')]
package version:
    #!/usr/bin/env bash
    set -euo pipefail
    export PACKAGE_VERSION='{{ version }}'
    ./build.sh
    ./test-binary.sh
    archive="openssh_${PACKAGE_VERSION}_darwin_arm64.tar.gz"
    mkdir -p .build/assets
    rm -f .build/assets/*.tar.gz .build/assets/*.sbom.json
    cp "build/dist/${archive}" ".build/assets/${archive}"
    SYFT_CHECK_FOR_APP_UPDATE=false SYFT_FILE_METADATA_CATALOGER_ENABLED=true \
        syft scan "file:.build/assets/${archive}" --source-name "${archive}" -o "spdx-json=.build/assets/${archive}.sbom.json"
    echo "package: .build/assets/${archive} and ${archive}.sbom.json"

# What goreleaser is handed must be this version's archive and its SBOM, and
# nothing else; every Mach-O in the archive signed under its org.forkcloser
# identifier, by Developer ID and timestamped on a release run, ad hoc
# accepted for a local dry run (`just do apple-verify-signed`); the SBOM an
# SPDX document naming the archive.
[doc("Assert .build/assets/ holds this version's archive, every binary signed, and its SBOM")]
verify-assets version:
    #!/usr/bin/env bash
    set -euo pipefail
    fail() { echo "verify-assets: $*" >&2; exit 1; }
    name='openssh_{{ version }}_darwin_arm64'
    archive=".build/assets/${name}.tar.gz"
    [ -f "$archive" ] || fail "$archive is missing"
    [ -f "$archive.sbom.json" ] || fail "$archive.sbom.json is missing"
    count=$(find .build/assets -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
    [ "$count" = 2 ] || fail ".build/assets holds $count entries, want the archive and its SBOM"
    rm -rf .build/assets-verify
    mkdir -p .build/assets-verify
    tar -xzf "$archive" -C .build/assets-verify
    [ -d ".build/assets-verify/${name}" ] || fail "$archive does not unpack to ${name}/"
    signed=0
    for bin in .build/assets-verify/"${name}"/bin/* .build/assets-verify/"${name}"/sbin/* .build/assets-verify/"${name}"/libexec/*; do
        case "$(file -b "$bin")" in
            *Mach-O*)
                just do apple-verify-signed "$bin"
                # Captured, then searched: piped straight into grep -q, which
                # closes the pipe at its match, codesign is killed by SIGPIPE
                # often enough under pipefail to fail a release (v10.6.1.5).
                details=$(codesign -d -v "$bin" 2>&1) || fail "codesign -d on ${bin##*/}: $details"
                printf '%s\n' "$details" | grep -qx "Identifier=org.forkcloser.${bin##*/}" || fail "${bin##*/} is not signed as org.forkcloser.${bin##*/}"
                signed=$((signed + 1))
                ;;
            *) ;;
        esac
    done
    [ "$signed" -gt 0 ] || fail "no Mach-O binary in $archive"
    grep -q '"spdxVersion"' "$archive.sbom.json" || fail "$archive.sbom.json is not an SPDX document"
    grep -q "\"name\": *\"${name}.tar.gz\"" "$archive.sbom.json" || fail "$archive.sbom.json does not name ${name}.tar.gz"
    echo "verify-assets: $archive holds ${signed} signed binaries, SBOM beside it"

# --- added by limen fix: the recipe the security workflow runs ---
security: do::security::default
