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

# --- added by limen fix: the recipe the security workflow runs ---
security: do::security::default
