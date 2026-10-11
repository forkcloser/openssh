#!/usr/bin/env bash
#
# Smoke test of the built package (build it first): unpacked somewhere else,
# every binary runs, reports the pinned OpenSSH without OpenSSL, knows the
# security-key algorithms and no RSA, reads the shipped ssh_config from its own
# prefix, executes its own ssh from scp, and the agent starts through the
# launch script. The package is relocated for the test, since that is the
# property that matters.

set -euo pipefail

cd "$(dirname "$0")"

openssh_version="$(limen pins get openssh version)"
package_version="${PACKAGE_VERSION:-${openssh_version/p/.}}"
name="openssh_${package_version}_darwin_arm64"
archive="build/dist/${name}.tar.gz"
[ -f "${archive}" ] || { echo "no archive to test: ${archive} (build it first)" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
tar -xzf "${archive}" -C "${work}"
# The real path: mktemp answers under /var, which is /private/var, and the
# binaries report where they really are.
prefix="$(cd "${work}/${name}" && pwd -P)"

# 1. The right OpenSSH, built without OpenSSL.
version="$("${prefix}/bin/ssh" -V 2>&1)"
echo "› ${version}"
[ "${version}" = "OpenSSH_${openssh_version}, without OpenSSL" ] || { echo "unexpected version line" >&2; exit 1; }

# 2. Security keys in, RSA out: the reason this package exists.
"${prefix}/bin/ssh" -Q key | grep -qx 'sk-ssh-ed25519@openssh.com' || { echo "no sk-ssh-ed25519 support" >&2; exit 1; }
"${prefix}/bin/ssh" -Q key | grep -q 'rsa' && { echo "RSA algorithms present" >&2; exit 1; }

# 3. The shipped ssh_config is read from the package's own etc/ssh, through a
# symlink too (a tool manager links bin/ssh from elsewhere).
"${prefix}/bin/ssh" -G example.com | grep -qx 'ciphers chacha20-poly1305@openssh.com,aes256-ctr' || { echo "the package's ssh_config was not read" >&2; exit 1; }
mkdir -p "${work}/elsewhere"
ln -s "${prefix}/bin/ssh" "${work}/elsewhere/ssh"
"${work}/elsewhere/ssh" -G example.com | grep -qx 'ciphers chacha20-poly1305@openssh.com,aes256-ctr' || { echo "the package's ssh_config was not read through a symlink" >&2; exit 1; }

# 4. scp executes the package's ssh, not a baked path.
# scp fails (nothing listens); its log is what is checked, from a file: under
# pipefail a grep -q that stops reading would fail the pipeline on its own.
"${prefix}/bin/scp" -v -o BatchMode=yes -o ConnectTimeout=1 nobody@127.0.0.1:none "${work}/none" > "${work}/scp.log" 2>&1 || true
grep -q "Executing: program ${prefix}/bin/ssh " "${work}/scp.log" || { echo "scp does not execute the package's ssh" >&2; exit 1; }

# 5. No build path survives in the client binaries. strings goes to a file
# first: under pipefail a grep -q that stops reading would fail the pipeline
# on a match, and the if would read that as a pass.
for bin in ssh ssh-agent ssh-add scp sftp; do
  strings "${prefix}/bin/${bin}" > "${work}/strings.txt"
  if grep -q -E '/(build|stage|Users/runner)/' "${work}/strings.txt"; then
    echo "${bin} carries a build path" >&2
    exit 1
  fi
done

# 6. The agent starts through the launch script, on a socket under a
# throwaway HOME, and answers ssh-add. The script runs with the system PATH,
# as launchd runs it: a tool manager's shims are not part of that environment.
home="${work}/home"
mkdir -p "${home}"
HOME="${home}" PATH=/usr/bin:/bin "${prefix}/libexec/ssh-agent-launchd" > "${work}/agent.log" 2>&1 &
agent=$!
trap 'kill "${agent}" 2>/dev/null; rm -rf "${work}"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "${home}/.ssh/agent.sock" ] && break
  sleep 0.5
done
[ -S "${home}/.ssh/agent.sock" ] || { cat "${work}/agent.log" >&2; echo "the agent did not bind its socket" >&2; exit 1; }
grep -q 'export SSH_AUTH_SOCK=' "${home}/.posh_ssh" || { echo ".posh_ssh was not written under the test HOME" >&2; exit 1; }
# ssh-add -l exits 1 on an empty agent: the answer is in its output.
SSH_AUTH_SOCK="${home}/.ssh/agent.sock" "${prefix}/bin/ssh-add" -l > "${work}/ssh-add.log" 2>&1 || true
grep -q 'The agent has no identities' "${work}/ssh-add.log" || { cat "${work}/ssh-add.log" >&2; echo "ssh-add cannot talk to the agent" >&2; exit 1; }

echo "✓ smoke: ${version} · sk-ed25519 · relocatable · scp → own ssh · agent runs"
