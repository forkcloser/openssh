# This file is the project's own — add recipes below. Keep the import: it
# mounts every shared limen task under `just do ...`.
import '.limen/just/main.just'

# The FIRST recipe defined here becomes `just`'s default.
lint: do::lint::default
fix: do::fix::default

# Build the package (macOS arm64 only): every source from pins.yaml, verified
# by digest; the result is build/dist/openssh_<version>_darwin_arm64.tar.gz.
# PACKAGE_VERSION=10.6.1.2 names a rebuild; the default is the pinned OpenSSH
# version with its portable level as the third segment.
build:
    ./build.sh

# Smoke-test the built package, relocated to a temp dir: version, security
# keys, the shipped config, scp's ssh, the agent through its launch script.
test:
    ./test-binary.sh

# The release assets' companions, per limen's signing and provenance policy
# (book/releasing.md): one SPDX JSON SBOM per archive by syft from the
# toolset, checksums.txt over the archives and the SBOMs, and cosign's
# keyless bundle over checksums.txt, signed with the workflow's OIDC identity
# and logged in Rekor. The release workflow's publish job runs it on the
# downloaded archives; a local run has no OIDC token and leaves checksums.txt
# unsigned, saying so. The directory is one inside the repository (dist, or
# under .build): the toolset's binaries resolve against the project's policy
# from the working directory, and the recipe does not leave it.
[doc('SBOM per archive, checksums.txt and its keyless cosign bundle, over a directory of archives')]
release-assets dir:
    #!/usr/bin/env bash
    set -euo pipefail
    dir='{{ dir }}'
    shopt -s nullglob
    archives=("$dir"/*.tar.gz)
    [ "${#archives[@]}" -gt 0 ] || { echo "release-assets: no archive in $dir" >&2; exit 1; }
    for archive in "${archives[@]}"; do
        SYFT_CHECK_FOR_APP_UPDATE=false SYFT_FILE_METADATA_CATALOGER_ENABLED=true \
            syft scan "file:$archive" --source-name "$(basename "$archive")" -o "spdx-json=$archive.sbom.json"
    done
    names=()
    for f in "$dir"/*.tar.gz "$dir"/*.sbom.json; do names+=("$(basename "$f")"); done
    (cd "$dir" && sha256sum -- "${names[@]}" > checksums.txt)
    if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
        cosign sign-blob --yes --bundle "$dir/checksums.txt.sigstore.json" "$dir/checksums.txt"
    else
        echo "release-assets: no OIDC token, $dir/checksums.txt is not signed (a local run)"
    fi

# --- added by limen fix: the recipe the security workflow runs ---
security: do::security::default
