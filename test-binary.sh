#!/usr/bin/env bash
#
# Smoke test of the built package (build it first): unpacked somewhere else,
# every binary runs, reports the pinned OpenSSH against the pinned LibreSSL,
# knows the security-key algorithms and P-256, negotiates neither RSA nor ECDSA
# unless a client asks for P-256, reads the shipped ssh_config from its own
# prefix, executes its own ssh from scp, the agent starts through the launch
# script, the server logs this user in with an ed25519 key and with a P-256
# key, and every binary carries its named signature. The package is relocated
# for the test, since that is the property that matters.

set -euo pipefail

cd "$(dirname "$0")"

openssh_version="$(limen pins get openssh version)"
libressl_version="$(limen pins get libressl version)"
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

# 1. The right OpenSSH, against the pinned LibreSSL.
version="$("${prefix}/bin/ssh" -V 2>&1)"
echo "› ${version}"
[ "${version}" = "OpenSSH_${openssh_version}, LibreSSL ${libressl_version}" ] || { echo "unexpected version line" >&2; exit 1; }

# 2. Security keys and P-256 in: the reasons this package exists. libcrypto
# brings RSA into the binary too; the shipped config keeps it, and every ECDSA
# form, out of each negotiation list, and a client asks for P-256 by naming
# the list it wants. A "+name" or "^name" on the command line is not that: it
# wins over the config file and extends the compiled-in defaults, RSA and the
# other curves included, so the check pins that too, as a warning to anyone
# tempted. ssh -G goes to a file: under pipefail a grep -q that stops reading
# would fail the pipeline on its own.
"${prefix}/bin/ssh" -Q key > "${work}/keys.txt"
for alg in sk-ssh-ed25519@openssh.com ecdsa-sha2-nistp256 sk-ecdsa-sha2-nistp256@openssh.com; do
  grep -qx "${alg}" "${work}/keys.txt" || { echo "no ${alg} support" >&2; exit 1; }
done
accepted='pubkeyacceptedalgorithms ssh-ed25519-cert-v01@openssh.com,sk-ssh-ed25519-cert-v01@openssh.com,ssh-mldsa44-ed25519-cert,ssh-ed25519,sk-ssh-ed25519@openssh.com,ssh-mldsa44-ed25519'
"${prefix}/bin/ssh" -G example.com > "${work}/effective.txt"
grep -qx "${accepted}" "${work}/effective.txt" || { echo "the shipped config does not pin the accepted key algorithms" >&2; exit 1; }
if grep -E '^(pubkeyaccepted|hostkey|casignature|hostbasedaccepted)algorithms ' "${work}/effective.txt" | grep -qE 'rsa|ecdsa'; then
  echo "RSA or ECDSA negotiated by default" >&2
  exit 1
fi
"${prefix}/bin/ssh" -G -o PubkeyAcceptedAlgorithms=ecdsa-sha2-nistp256 example.com > "${work}/effective-p256.txt"
grep -qx 'pubkeyacceptedalgorithms ecdsa-sha2-nistp256' "${work}/effective-p256.txt" || { echo "a named list does not select P-256 alone" >&2; exit 1; }
"${prefix}/bin/ssh" -G -o PubkeyAcceptedAlgorithms=+ecdsa-sha2-nistp256 example.com > "${work}/effective-plus.txt"
grep -E '^pubkeyacceptedalgorithms ' "${work}/effective-plus.txt" | grep -q 'rsa' || { echo "+ecdsa-sha2-nistp256 no longer extends the compiled-in defaults: revisit the README's advice" >&2; exit 1; }

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

# 5. No build path survives in the binaries. strings goes to a file first:
# under pipefail a grep -q that stops reading would fail the pipeline on a
# match, and the if would read that as a pass.
for bin in bin/ssh bin/ssh-agent bin/ssh-add bin/scp bin/sftp sbin/sshd libexec/sshd-session libexec/sshd-auth libexec/sftp-server; do
  strings "${prefix}/${bin}" > "${work}/strings.txt"
  if grep -q -E '/(build|stage|Users/runner)/' "${work}/strings.txt"; then
    echo "${bin} carries a build path" >&2
    exit 1
  fi
done

# 6. The agent starts through the launch script, on a socket under a
# throwaway HOME, and answers ssh-add. The script runs with the system PATH,
# as launchd runs it: a tool manager's shims are not part of that environment.
# A throwaway HOME is not the account's, so the login session's SSH_AUTH_SOCK
# is left alone, by the script's own guard.
home="${work}/home"
mkdir -p "${home}"
HOME="${home}" PATH=/usr/bin:/bin "${prefix}/libexec/ssh-agent-launchd" > "${work}/agent.log" 2>&1 &
agent=$!
trap 'kill "${agent}" 2>/dev/null; rm -rf "${work}"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "${home}/.ssh/org.forkcloser.agent.sock" ] && break
  sleep 0.5
done
[ -S "${home}/.ssh/org.forkcloser.agent.sock" ] || { cat "${work}/agent.log" >&2; echo "the agent did not bind its socket" >&2; exit 1; }
# ssh-add -l exits 1 on an empty agent: the answer is in its output.
SSH_AUTH_SOCK="${home}/.ssh/org.forkcloser.agent.sock" "${prefix}/bin/ssh-add" -l > "${work}/ssh-add.log" 2>&1 || true
grep -q 'The agent has no identities' "${work}/ssh-add.log" || { cat "${work}/ssh-add.log" >&2; echo "ssh-add cannot talk to the agent" >&2; exit 1; }

# 7. The server, as this user, on an ephemeral port: the shipped sshd_config
# is read from the package (no -f: the relocated default), the config test
# passes with a fresh host key, and a login with a key from a throwaway
# authorized_keys gets a session through the package's own sshd-session (the
# relocated helper path, no override). -p replaces the file's port outright
# (a -o Port would add to it, and the file's 22 would be bound beside it);
# the file's any-address listeners stay, for the seconds the test takes.
# StrictModes is off for the test alone: the throwaway authorized_keys sits
# under a temp dir whose chain the check rightly refuses. The server is given
# the list a server admitting the enclave key is given: its own and P-256, and
# room for the account's own identities, which the shipped ssh_config names
# and the client offers ahead of the test's: each refusal counts against
# MaxAuthTries, and the shipped one is too few for the refusal check below to
# end in "Permission denied" rather than "Too many authentication failures".
"${prefix}/bin/ssh-keygen" -q -t ed25519 -N '' -f "${work}/hostkey"
"${prefix}/bin/ssh-keygen" -q -t ed25519 -N '' -f "${work}/id"
"${prefix}/bin/ssh-keygen" -q -t ecdsa -b 256 -N '' -f "${work}/id_p256"
cat "${work}/id.pub" "${work}/id_p256.pub" > "${work}/authorized_keys"
port=$((20000 + RANDOM % 20000))
"${prefix}/sbin/sshd" -t -h "${work}/hostkey" -p "${port}" -o "AuthorizedKeysFile=${work}/authorized_keys" -o StrictModes=no -o PubkeyAcceptedAlgorithms=ssh-ed25519,ecdsa-sha2-nistp256 -o MaxAuthTries=6
"${prefix}/sbin/sshd" -D -h "${work}/hostkey" -p "${port}" -o "AuthorizedKeysFile=${work}/authorized_keys" -o StrictModes=no -o PubkeyAcceptedAlgorithms=ssh-ed25519,ecdsa-sha2-nistp256 -o MaxAuthTries=6 -E "${work}/sshd.log" &
sshd=$!
trap 'kill "${agent}" "${sshd}" 2>/dev/null; rm -rf "${work}"' EXIT
# -F names the shipped config as the user's: ssh reads ~/.ssh/config from the
# passwd home whatever HOME says, and the test is of the shipped config alone.
logged_in=
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if "${prefix}/bin/ssh" -F "${prefix}/etc/ssh/ssh_config" -p "${port}" -i "${work}/id" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o "UserKnownHostsFile=${work}/known_hosts" -o ConnectTimeout=2 "$(id -un)@127.0.0.1" 'echo session-ok' > "${work}/ssh.out" 2> "${work}/ssh.err"; then
    logged_in=1
    break
  fi
  sleep 0.5
done
if [ -z "${logged_in}" ] || ! grep -qx 'session-ok' "${work}/ssh.out"; then
  cat "${work}/ssh.err" "${work}/sshd.log" >&2
  echo "no session through the package's sshd" >&2
  exit 1
fi
grep -q 'Accepted publickey.*ED25519' "${work}/sshd.log" || { cat "${work}/sshd.log" >&2; echo "sshd did not log the ed25519 login" >&2; exit 1; }

# 8. The P-256 key, the enclave key's path: refused by the shipped config
# alone, accepted once the client names it, through libcrypto on both sides.
common=(-F "${prefix}/etc/ssh/ssh_config" -p "${port}" -i "${work}/id_p256" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=no -o "UserKnownHostsFile=${work}/known_hosts" -o ConnectTimeout=2)
if "${prefix}/bin/ssh" "${common[@]}" "$(id -un)@127.0.0.1" 'echo p256-unasked' > "${work}/ssh-p256-unasked.out" 2>&1; then
  echo "the P-256 key authenticated without being asked for" >&2
  exit 1
fi
# The refusal has a name; any other failure here is not the shipped config's.
grep -q 'Permission denied (publickey)' "${work}/ssh-p256-unasked.out" || { cat "${work}/ssh-p256-unasked.out" >&2; echo "the P-256 key was not refused for its algorithm" >&2; exit 1; }
"${prefix}/bin/ssh" "${common[@]}" -o PubkeyAcceptedAlgorithms=ecdsa-sha2-nistp256 "$(id -un)@127.0.0.1" 'echo p256-ok' > "${work}/ssh-p256.out" 2> "${work}/ssh-p256.err" || {
  cat "${work}/ssh-p256.err" "${work}/sshd.log" >&2
  echo "no session with the P-256 key" >&2
  exit 1
}
grep -qx 'p256-ok' "${work}/ssh-p256.out" || { echo "no session with the P-256 key" >&2; exit 1; }
grep -q 'Accepted publickey.*ECDSA' "${work}/sshd.log" || { cat "${work}/sshd.log" >&2; echo "sshd did not log the P-256 login" >&2; exit 1; }

# 9. Every binary carries its named ad-hoc signature.
for bin in bin/ssh bin/ssh-keygen bin/ssh-agent bin/ssh-add bin/scp bin/sftp sbin/sshd libexec/ssh-sk-helper libexec/sshd-session; do
  codesign -d -v "${prefix}/${bin}" 2> "${work}/codesign.txt"
  grep -qx "Identifier=org.forkcloser.${bin##*/}" "${work}/codesign.txt" || { cat "${work}/codesign.txt" >&2; echo "${bin} is not signed as org.forkcloser.${bin##*/}" >&2; exit 1; }
done

echo "✓ smoke: ${version} · sk-ed25519 · P-256 on request only · relocatable · scp → own ssh · agent runs · sshd logs this user in, ed25519 and P-256 · signed org.forkcloser.*"
