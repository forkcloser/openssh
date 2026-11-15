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

# The shipped ssh_config includes the file SSH_CONFIG_INCLUDE names, and a
# session of the rig runs with one set that pins its own algorithms: the test
# is of the shipped config alone, and 3b sets the variable itself where the
# include is what is tested.
unset SSH_CONFIG_INCLUDE

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

# 0. The archive is its contract: the entries config/archive-contents lists,
# each with the mode it lists, and nothing else. Every check below that is
# about the binaries takes them from this tree, never from a typed list: a
# binary a list forgot is one nothing checks.
# The system stat by path: the hermetic PATH's is uutils', with GNU flags.
# Sorted as bytes: a locale orders "ssh-keygen" and "sshd-install" its own way.
(cd "${prefix}" && find . -mindepth 1 | LC_ALL=C sort | while read -r entry; do
  printf '%s %s\n' "$(/usr/bin/stat -f '%Sp' "${entry}")" "${entry#./}"
done) > "${work}/contents.txt"
if ! diff config/archive-contents "${work}/contents.txt" > "${work}/contents.diff"; then
  cat "${work}/contents.diff" >&2
  echo "the archive is not what config/archive-contents lists (<: listed, >: in the archive)" >&2
  exit 1
fi
: > "${work}/binaries.txt"
while read -r _ entry; do
  [ -f "${prefix}/${entry}" ] || continue
  case "$(file -b "${prefix}/${entry}")" in
    *Mach-O*) echo "${entry}" >> "${work}/binaries.txt" ;;
    *) ;;
  esac
done < config/archive-contents
[ -s "${work}/binaries.txt" ] || { echo "no Mach-O in the archive" >&2; exit 1; }

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

# 3b. The include gate: with SSH_CONFIG_INCLUDE naming a file, its options are
# read ahead of the defaults (it says Compression yes, the shipped default is
# no), wherever
# HOME points; unset, the defaults and nothing on stderr (OpenSSH would
# complain of the unset variable on every run without include-env.patch);
# set to a missing file, the defaults, nothing on stderr, exit 0. env -u for
# the unset case: a session running this test may have the variable itself.
printf 'Compression yes\n' > "${work}/extra_config"
SSH_CONFIG_INCLUDE="${work}/extra_config" "${prefix}/bin/ssh" -G example.com > "${work}/include.txt" 2> "${work}/include.err"
grep -qx 'compression yes' "${work}/include.txt" || { echo "the SSH_CONFIG_INCLUDE file was not read" >&2; exit 1; }
mkdir -p "${work}/elsewhere-home"
HOME="${work}/elsewhere-home" SSH_CONFIG_INCLUDE="${work}/extra_config" "${prefix}/bin/ssh" -G example.com > "${work}/include-home.txt" 2> "${work}/include-home.err"
grep -qx 'compression yes' "${work}/include-home.txt" || { echo "the SSH_CONFIG_INCLUDE file was not read with HOME elsewhere" >&2; exit 1; }
env -u SSH_CONFIG_INCLUDE "${prefix}/bin/ssh" -G example.com > "${work}/no-include.txt" 2> "${work}/no-include.err"
grep -qx 'compression no' "${work}/no-include.txt" || { echo "an option was read without SSH_CONFIG_INCLUDE" >&2; exit 1; }
grep -v 'Pseudo-terminal' "${work}/no-include.err" | grep -q . && { echo "ssh -G without SSH_CONFIG_INCLUDE printed to stderr:" >&2; cat "${work}/no-include.err" >&2; exit 1; }
SSH_CONFIG_INCLUDE="${work}/no-such-config" "${prefix}/bin/ssh" -G example.com > "${work}/include-missing.txt" 2> "${work}/include-missing.err" || { echo "a missing SSH_CONFIG_INCLUDE file is an error" >&2; exit 1; }
grep -qx 'compression no' "${work}/include-missing.txt" || { echo "a missing SSH_CONFIG_INCLUDE file changed the options" >&2; exit 1; }
grep -v 'Pseudo-terminal' "${work}/include-missing.err" | grep -q . && { echo "ssh -G with a missing SSH_CONFIG_INCLUDE file printed to stderr:" >&2; cat "${work}/include-missing.err" >&2; exit 1; }

# 3c. Out of its tree, ssh refuses to run: a binary copied elsewhere finds no
# etc/ssh above it, and would otherwise run on OpenSSH's compiled-in
# defaults, RSA and all, without a word. A configuration the user names is
# theirs to choose: -F still works there.
mkdir -p "${work}/outside/bin"
cp "${prefix}/bin/ssh" "${work}/outside/bin/ssh"
if "${work}/outside/bin/ssh" -G example.com > "${work}/outside.txt" 2> "${work}/outside.err"; then
  echo "ssh ran without its package's ssh_config" >&2
  exit 1
fi
grep -q "no ssh_config under $(cd "${work}/outside" && pwd -P)/etc/ssh" "${work}/outside.err" || { cat "${work}/outside.err" >&2; echo "ssh out of its tree did not say what it lacks" >&2; exit 1; }
"${work}/outside/bin/ssh" -F "${prefix}/etc/ssh/ssh_config" -G example.com > "${work}/outside-F.txt" 2> /dev/null || { echo "ssh out of its tree refused a configuration named with -F" >&2; exit 1; }
grep -qx 'ciphers chacha20-poly1305@openssh.com,aes256-ctr' "${work}/outside-F.txt" || { echo "ssh out of its tree did not read the configuration named with -F" >&2; exit 1; }
"${work}/outside/bin/ssh" -F none -G example.com > /dev/null 2>&1 || { echo "ssh out of its tree refused -F none" >&2; exit 1; }

# 4. scp executes the package's ssh, not a baked path.
# scp fails (nothing listens); its log is what is checked, from a file: under
# pipefail a grep -q that stops reading would fail the pipeline on its own.
"${prefix}/bin/scp" -v -o BatchMode=yes -o ConnectTimeout=1 nobody@127.0.0.1:none "${work}/none" > "${work}/scp.log" 2>&1 || true
grep -q "Executing: program ${prefix}/bin/ssh " "${work}/scp.log" || { echo "scp does not execute the package's ssh" >&2; exit 1; }

# 5. No build path survives in the binaries. strings goes to a file first:
# under pipefail a grep -q that stops reading would fail the pipeline on a
# match, and the if would read that as a pass.
while read -r bin; do
  strings "${prefix}/${bin}" > "${work}/strings.txt"
  if grep -q -E '/(build|stage|Users/runner)/' "${work}/strings.txt"; then
    echo "${bin} carries a build path" >&2
    exit 1
  fi
done < "${work}/binaries.txt"

# 5b. Every Mach-O of the package, found in the tree and not from a list,
# links the libraries config/system-libraries names and no other; and the
# README, which gives that list to a reader, names each of them.
while read -r file; do
  case "$(file -b "${file}")" in
    *Mach-O*)
      if otool -L "${file}" | sed 1d | awk '{print $1}' | grep -v -x -F -f config/system-libraries > "${work}/unlisted.txt"; then
        cat "${work}/unlisted.txt" >&2
        echo "${file#"${prefix}/"} links a library config/system-libraries does not name" >&2
        exit 1
      fi
      ;;
    *) ;;
  esac
done < <(find "${prefix}" -type f)
while read -r library; do
  short="${library##*/}"
  short="${short%%.*}"
  grep -q "${short}" README.md || { echo "the README does not name ${short}, which config/system-libraries lists" >&2; exit 1; }
done < config/system-libraries

# 5c. The notices of the sources, beside the four projects' own licence
# files: a part for each tree linked, and holders a reading of the first
# comment alone, or of the projects' summaries, leaves out: Otto Moerbeek
# (two files OpenSSH and libfido2 compile where the system has neither
# function), David Gwynne (a second notice far inside a header), Andre Lucas
# (a notice after an include guard), Bjoern Hoehrmann (named by a source
# that states no terms).
notices="${prefix}/share/licenses/NOTICES"
[ -s "${notices}" ] || { echo "no share/licenses/NOTICES in the package" >&2; exit 1; }
for part in 'OpenSSH' 'OpenSSH openbsd-compat' 'LibreSSL libcrypto' 'LibreSSL headers' 'libfido2' 'libfido2 openbsd-compat' 'libcbor' 'libcbor, the UTF-8 decoder it compiles'; do
  grep -qx "${part}" "${notices}" || { echo "NOTICES has no part for ${part}" >&2; exit 1; }
done
for holder in 'Otto Moerbeek' 'Tatu Ylonen' 'Eric Young' 'Yubico AB' 'Pavel Kalvoda' 'David Gwynne' 'Andre Lucas' 'Bjoern Hoehrmann'; do
  grep -q "${holder}" "${notices}" || { echo "NOTICES does not name ${holder}" >&2; exit 1; }
done
for summary in openssh libfido2 libcbor libressl; do
  [ -s "${prefix}/share/licenses/${summary}" ] || { echo "no share/licenses/${summary} in the package" >&2; exit 1; }
done

# 5d. Every Mach-O is built for the macOS the README promises: its load
# command gives 15.0 as the oldest system it runs on, and the README says so.
grep -q 'macOS 15\.0 and later' README.md || { echo "the README does not state macOS 15.0 and later" >&2; exit 1; }
while read -r file; do
  case "$(file -b "${file}")" in
    *Mach-O*)
      minos="$(otool -l "${file}" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
      [ "${minos}" = 15.0 ] || { echo "${file#"${prefix}/"} is built for macOS ${minos:-<none>}, the README says 15.0" >&2; exit 1; }
      ;;
    *) ;;
  esac
done < <(find "${prefix}" -type f)

# 6. The agent starts through the launch script, on a socket under a
# throwaway HOME, writes the env file a shell sources, and answers ssh-add.
# The script runs with the system PATH, as launchd runs it: a tool manager's
# shims are not part of that environment. A throwaway HOME is not the
# account's, so the login session's SSH_AUTH_SOCK is left alone, by the
# script's own guard. Its stderr is where the LaunchAgent's plist puts it,
# appended as launchd appends, onto a log already past the size the script
# keeps.
home="${work}/home"
agent_log="${home}/Library/Logs/org.forkcloser.ssh_agent/stderr.log"
mkdir -p "${agent_log%/*}"
head -c 4194305 /dev/zero > "${agent_log}"
HOME="${home}" PATH=/usr/bin:/bin "${prefix}/libexec/ssh-agent-launchd" > "${work}/agent.log" 2>> "${agent_log}" &
agent=$!
trap 'kill "${agent}" 2>/dev/null; rm -rf "${work}"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "${home}/.ssh/org.forkcloser.agent.sock" ] && break
  sleep 0.5
done
[ -S "${home}/.ssh/org.forkcloser.agent.sock" ] || { cat "${work}/agent.log" "${agent_log}" >&2; echo "the agent did not bind its socket" >&2; exit 1; }
# The full log was set aside and the agent writes to a new one: a rename
# alone would leave it writing to the old.
[ "$(/usr/bin/stat -f '%z' "${agent_log}.1")" -ge 4194305 ] || { echo "the launch script did not set the full stderr.log aside" >&2; exit 1; }
[ "$(/usr/bin/stat -f '%z' "${agent_log}")" -lt 4194305 ] || { echo "the agent still writes to the full stderr.log" >&2; exit 1; }
env_file="${home}/.ssh/org.forkcloser.agent.env"
# The system stat by path: the hermetic PATH's is uutils', with GNU flags.
[ "$(/usr/bin/stat -f '%Lp' "${env_file}")" = 600 ] || { echo "the env file is not there with mode 0600" >&2; exit 1; }
# Sourced under that HOME, as an rc would, it names the socket served.
sourced="$(HOME="${home}" sh -c '. "$HOME/.ssh/org.forkcloser.agent.env" && printf %s "$SSH_AUTH_SOCK"')"
[ "${sourced}" = "${home}/.ssh/org.forkcloser.agent.sock" ] || { echo "the env file names ${sourced}" >&2; exit 1; }
# ssh-add -l exits 1 on an empty agent: the answer is in its output.
SSH_AUTH_SOCK="${home}/.ssh/org.forkcloser.agent.sock" "${prefix}/bin/ssh-add" -l > "${work}/ssh-add.log" 2>&1 || true
grep -q 'The agent has no identities' "${work}/ssh-add.log" || { cat "${work}/ssh-add.log" >&2; echo "ssh-add cannot talk to the agent" >&2; exit 1; }

# 6b. The installer makes a bash login shell find the agent whichever file
# that shell reads: ~/.profile where it is alone, the ~/.bash_profile that
# is there, the ~/.bash_login that is there without one; neither of the two
# is ever created. Under a throwaway
# HOME each, with the env file the launch script wrote above (its line is
# relative to HOME), and a launchctl that does nothing first on the PATH
# launchd gives: nothing is loaded into this account's session. The shell
# starts without the variable, or the one this test runs with would answer.
# Uninstall takes the lines out again and leaves what the user wrote.
mkdir -p "${work}/stub"
printf '#!/bin/sh\nexit 0\n' > "${work}/stub/launchctl"
chmod 0755 "${work}/stub/launchctl"
for kind in plain profile login; do
  rc_home="${work}/home-${kind}"
  mkdir -p "${rc_home}/.ssh"
  cp "${env_file}" "${rc_home}/.ssh/org.forkcloser.agent.env"
  written=("${rc_home}/.zshrc" "${rc_home}/.bashrc" "${rc_home}/.profile")
  own=
  [ "${kind}" = plain ] || own="${rc_home}/.bash_${kind}"
  if [ -n "${own}" ]; then
    printf 'export KEPT=1\n' > "${own}"
    written+=("${own}")
  fi
  HOME="${rc_home}" PATH="${work}/stub:/usr/bin:/bin" "${prefix}/bin/ssh-agent-install" > /dev/null
  # shellcheck disable=SC2016 # the variable is the login shell's to expand
  seen="$(env -u SSH_AUTH_SOCK HOME="${rc_home}" /bin/bash -l -c 'printf %s "${SSH_AUTH_SOCK:-}"' 2> /dev/null)"
  [ "${seen}" = "${rc_home}/.ssh/org.forkcloser.agent.sock" ] || { echo "a bash login shell (${kind}) has SSH_AUTH_SOCK '${seen}' after ssh-agent-install" >&2; exit 1; }
  for made in "${rc_home}/.bash_profile" "${rc_home}/.bash_login"; do
    [ "${made}" = "${own}" ] || [ ! -e "${made}" ] || { echo "ssh-agent-install (${kind}) created ${made##*/}" >&2; exit 1; }
  done
  HOME="${rc_home}" PATH="${work}/stub:/usr/bin:/bin" "${prefix}/bin/ssh-agent-install" uninstall > /dev/null
  if grep -q 'org.forkcloser' "${written[@]}"; then
    echo "ssh-agent-install uninstall (${kind}) left its line in an rc" >&2
    exit 1
  fi
  [ -z "${own}" ] || grep -qx 'export KEPT=1' "${own}" || { echo "ssh-agent-install uninstall took the user's line out of ${own##*/}" >&2; exit 1; }
done

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

# 7a. The agent logs every sign request, in its stderr.log: a login through
# it names the key, the server's host key and the user, and the ssh that
# asked by the cdhash codesign reports for that file and by its real path; a
# signature that is not a login says so; a request it refuses has its line
# too. The key leaves the agent afterwards: the checks below are of keys
# given by file.
agent_sock="${home}/.ssh/org.forkcloser.agent.sock"
fingerprint() { "${prefix}/bin/ssh-keygen" -lf "$1" | awk '{ print $2 }'; }
cdhash() { codesign -d -vvv "$1" 2>&1 | awk -F= '$1 == "CDHash" { print $2 }'; }
SSH_AUTH_SOCK="${agent_sock}" "${prefix}/bin/ssh-add" -q "${work}/id"
"${prefix}/bin/ssh" -F "${prefix}/etc/ssh/ssh_config" -p "${port}" -i "${work}/id.pub" -o IdentitiesOnly=yes -o "IdentityAgent=${agent_sock}" -o BatchMode=yes -o StrictHostKeyChecking=no -o "UserKnownHostsFile=${work}/known_hosts" -o ConnectTimeout=2 "$(id -un)@127.0.0.1" true 2> "${work}/ssh.err" ||
  { cat "${work}/ssh.err" "${agent_log}" >&2; echo "no login with the key the agent holds" >&2; exit 1; }
SSH_AUTH_SOCK="${agent_sock}" "${prefix}/bin/ssh-add" -T "${work}/id.pub" > /dev/null 2>&1 || { echo "the agent did not sign for ssh-add -T" >&2; exit 1; }
if SSH_AUTH_SOCK="${agent_sock}" "${prefix}/bin/ssh-add" -T "${work}/id_p256.pub" > /dev/null 2>&1; then
  echo "the agent signed with a key it does not hold" >&2
  exit 1
fi
SSH_AUTH_SOCK="${agent_sock}" "${prefix}/bin/ssh-add" -q -D
ssh_real="$(readlink -f "${prefix}/bin/ssh")"
add_real="$(readlink -f "${prefix}/bin/ssh-add")"
[ "$(cdhash "${ssh_real}" | grep -cE '^[0-9a-f]{40}$')" = 1 ] || { echo "codesign gives no cdhash for ${ssh_real}" >&2; exit 1; }
# The time and the pid are the fields the test cannot know, and the time
# has one shape. OpenSSH ends a line on stderr with a carriage return before
# the newline.
tr -d '\r' < "${agent_log}" | sed -E -e 's/ at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z key / at T key /' -e 's/ by pid [0-9]+ / by pid N /' > "${work}/agent-signs.txt"
for line in \
  "sign ok at T key ED25519 $(fingerprint "${work}/id.pub") to hostkey ED25519 $(fingerprint "${work}/hostkey.pub") user $(id -un) by pid N cdhash $(cdhash "${ssh_real}") path ${ssh_real}" \
  "sign ok at T key ED25519 $(fingerprint "${work}/id.pub") to - (not a login) by pid N cdhash $(cdhash "${add_real}") path ${add_real}" \
  "sign refused at T key ECDSA $(fingerprint "${work}/id_p256.pub") to - (not a login) by pid N cdhash $(cdhash "${add_real}") path ${add_real}"; do
  grep -qxF -- "${line}" "${work}/agent-signs.txt" || { cat "${agent_log}" >&2; echo "the agent's log has no line: ${line}" >&2; exit 1; }
done
[ "$(grep -c '^sign ' "${agent_log}")" = 3 ] || { cat "${agent_log}" >&2; echo "the agent's log does not have one line a request" >&2; exit 1; }

# 7b. The server runs on what the shipped sshd_config states: every option
# of the file is in `sshd -T`, as written, whatever the letters' case. Five
# are printed in another notation than the file's: a listener with its port,
# a time in seconds, a size in bytes, TCPKeepAlive's no as false, and
# AcceptEnv one name a line.
"${prefix}/sbin/sshd" -T -h "${work}/hostkey" | tr '[:upper:]' '[:lower:]' > "${work}/sshd-T.txt"
grep -v -e '^#' -e '^$' "${prefix}/etc/ssh/sshd_config" | tr '[:upper:]' '[:lower:]' > "${work}/sshd-stated.txt"
while read -r key value; do
  case "${key}" in
    listenaddress)
      case "${value}" in *:*) value="[${value}]:22" ;; *) value="${value}:22" ;; esac
      ;;
    logingracetime) value="${value%s}" ;;
    rekeylimit) value="1073741824 3600" ;;
    tcpkeepalive) [ "${value}" != no ] || value=false ;;
    acceptenv)
      # Into an array: a bare ${value} would have the shell match lc_* against
      # the working directory's files.
      read -r -a names <<< "${value}"
      for name in "${names[@]}"; do
        grep -qxF "${key} ${name}" "${work}/sshd-T.txt" || { echo "sshd -T does not have '${key} ${name}', which sshd_config states" >&2; exit 1; }
      done
      continue
      ;;
    *) ;;
  esac
  grep -qxF "${key} ${value}" "${work}/sshd-T.txt" || { echo "sshd -T does not have '${key} ${value}', which sshd_config states" >&2; exit 1; }
done < "${work}/sshd-stated.txt"

# 7c. Nothing is forwarded, a unix socket no more than a port: the server
# refuses the listener a client asks it for, and the client, told to stop on
# a forward it cannot have, stops.
forward=(-F "${prefix}/etc/ssh/ssh_config" -p "${port}" -i "${work}/id" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=no -o "UserKnownHostsFile=${work}/known_hosts" -o ConnectTimeout=2 -o ExitOnForwardFailure=yes)
for listener in "${work}/forwarded.sock:127.0.0.1:9" "127.0.0.1:0:127.0.0.1:9"; do
  if "${prefix}/bin/ssh" "${forward[@]}" -R "${listener}" "$(id -un)@127.0.0.1" 'echo forwarded' > "${work}/forward.out" 2>&1; then
    cat "${work}/forward.out" >&2
    echo "the server forwarded ${listener}" >&2
    exit 1
  fi
  grep -qi 'forwarding failed' "${work}/forward.out" || { cat "${work}/forward.out" >&2; echo "the refusal of ${listener} was not a forwarding refusal" >&2; exit 1; }
done

# 7d. The server's log, set aside: sshd-install does it past 4 MB, with a
# launchctl that does nothing first on the PATH launchd gives (it answers
# that the server is this agent's own, so port 22 is not looked at), under
# a throwaway HOME; a log of exactly 4 MB, and a small one, stay where they
# are. And a log set aside under a running server, which is what a rename by
# hand does: the next connection writes to a new file, each connection
# opening the path itself.
mkdir -p "${work}/sshd-stub"
printf '#!/bin/sh\nexit 0\n' > "${work}/sshd-stub/launchctl"
chmod 0755 "${work}/sshd-stub/launchctl"
for size in 4194305 4194304 1024; do
  sshd_home="${work}/home-sshd-${size}"
  sshd_log="${sshd_home}/Library/Logs/org.forkcloser.sshd/sshd.log"
  mkdir -p "${sshd_log%/*}"
  head -c "${size}" /dev/zero > "${sshd_log}"
  HOME="${sshd_home}" XDG_STATE_HOME='' PATH="${work}/sshd-stub:/usr/bin:/bin:/usr/sbin:/sbin" "${prefix}/bin/sshd-install" > /dev/null
  aside=0
  [ ! -e "${sshd_log}.1" ] || aside="$(/usr/bin/stat -f '%z' "${sshd_log}.1")"
  if [ "${size}" -gt 4194304 ]; then
    if [ -e "${sshd_log}" ] || [ "${aside}" != "${size}" ]; then echo "sshd-install did not set a ${size}-byte sshd.log aside" >&2; exit 1; fi
  else
    if [ "${aside}" != 0 ] || [ "$(/usr/bin/stat -f '%z' "${sshd_log}")" != "${size}" ]; then echo "sshd-install set a ${size}-byte sshd.log aside" >&2; exit 1; fi
  fi
done
mv "${work}/sshd.log" "${work}/sshd.log.1"
"${prefix}/bin/ssh" -F "${prefix}/etc/ssh/ssh_config" -p "${port}" -i "${work}/id" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=no -o "UserKnownHostsFile=${work}/known_hosts" -o ConnectTimeout=2 "$(id -un)@127.0.0.1" true 2> "${work}/ssh.err" ||
  { cat "${work}/ssh.err" "${work}/sshd.log.1" >&2; echo "no login after the server's log was set aside" >&2; exit 1; }
grep -q 'Accepted publickey.*ED25519' "${work}/sshd.log" 2> /dev/null || { cat "${work}/sshd.log.1" >&2; echo "the login after the log was set aside is not in a new sshd.log" >&2; exit 1; }

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

# 9. Every binary carries its named signature: ad hoc in a local build, the
# Developer ID's in a release (verify-assets asserts which). On a Developer ID
# build the four binaries that dlopen a user-named library carry the
# entitlement that turns library validation off, and no other binary does.
while read -r bin; do
  codesign -d -v "${prefix}/${bin}" 2> "${work}/codesign.txt"
  grep -qx "Identifier=org.forkcloser.${bin##*/}" "${work}/codesign.txt" || { cat "${work}/codesign.txt" >&2; echo "${bin} is not signed as org.forkcloser.${bin##*/}" >&2; exit 1; }
  if grep -q '^Authority=Developer ID Application' "${work}/codesign.txt"; then
    case "${bin##*/}" in
      ssh | ssh-keygen | ssh-pkcs11-helper | ssh-sk-helper) want=1 ;;
      *) want=0 ;;
    esac
    have="$(codesign -d --entitlements - --xml "${prefix}/${bin}" 2> /dev/null | grep -c 'com.apple.security.cs.disable-library-validation' || true)"
    [ "${have}" = "${want}" ] || { echo "${bin}: library validation entitlement present ${have} time(s), want ${want}" >&2; exit 1; }
  fi
done < "${work}/binaries.txt"

echo "✓ smoke: ${version} · sk-ed25519 · P-256 on request only · relocatable · scp → own ssh · agent runs · sshd logs this user in, ed25519 and P-256 · signed org.forkcloser.*"
