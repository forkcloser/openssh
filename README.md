# openssh

OpenSSH for macOS with security keys built in, as one relocatable package for
the toolchain, installed and pinned through aqua like everything
else. Exists because Apple's OpenSSH is built without FIDO support, so an
`sk-ssh-ed25519@openssh.com` key (a YubiKey, a Secure Enclave through a
provider) is unusable with the system `ssh`, `ssh-agent` and `ssh-keygen`.

What the package is:

- **OpenSSH portable**: the client set (`ssh`, `ssh-agent`, `ssh-add`,
  `ssh-keygen`, `scp`, `sftp`, `ssh-keyscan`, the `ssh-sk-helper` and
  `ssh-pkcs11-helper` they spawn) and the server (`sshd` with its two
  helpers), the server off by default and user-scoped when on.
- **Built against LibreSSL's libcrypto**: ed25519 and the security-key forms,
  the post-quantum hybrid key exchange, and ECDSA P-256, the one algorithm a
  Secure Enclave key signs with, so the bot's enclave key (taciturn's agent)
  authenticates through this `ssh` and no other. libcrypto brings RSA and its
  ciphers and key exchanges along, and OpenSSH cannot compile ECDSA in and RSA
  out; the shipped `ssh_config` keeps every one of them, P-256 included, out of
  negotiation, and a client holding an enclave key names the list it wants:
  `-o PubkeyAcceptedAlgorithms=ecdsa-sha2-nistp256`. Not `+ecdsa-sha2-nistp256`:
  a `+` or `^` on the command line wins over the config file and extends
  OpenSSH's compiled-in defaults, which would put RSA and the other curves back
  on offer. `ssh -V` says `OpenSSH_<version>, LibreSSL <version>`.
- **LibreSSL, libfido2 and libcbor linked statically.** The binaries link the
  system (libSystem, libz, libresolv, CoreFoundation, IOKit) and nothing else;
  `build.sh` refuses anything else.
- **Apple's clang and SDK** (libedit, zlib), on the macOS runner: the
  toolchain the readiness audit files under the rig, as curl's mac leg.
- **A client configuration**, `etc/ssh/ssh_config`: a strict, current
  baseline. ed25519 and its security-key and ML-DSA hybrid forms only,
  certificates first; the post-quantum hybrid key exchanges (ML-KEM, then
  sntrup761) ahead of X25519; ChaCha20-Poly1305 ahead of AES-256-CTR with an
  encrypt-then-MAC SHA-512 tag. `~/.ssh/config` still comes first and
  overrides it.
- **The agent as a LaunchAgent**: the launch script, its plist and an
  installer, which were this repository's whole content before the package.
- **A named ad-hoc signature** on every binary: `org.forkcloser.ssh`,
  `org.forkcloser.ssh-keygen` and so on, where the linker's own ad-hoc
  signature carries the file name. An ad-hoc identifier proves no origin
  (anything can sign itself that); it is the stable label an agent's peer
  check names a binary by, next to its path, and the cdhash in that agent's
  log is what identifies the build that asked.

darwin/arm64 only: Intel Mac support was dropped, and Linux has
distribution packages with FIDO support.

## Relocation

OpenSSH bakes its configuration directory and its helper paths at build
time, which is why Homebrew's build lives in a Cellar and why Apple's reads
`/etc/ssh`. This package carries a patch (`patches/relocate.patch`) that
resolves both from the running executable instead: `<prefix>/etc/ssh` and
`<prefix>/libexec`, where `<prefix>` is the directory above the binary's real
path (`bin/` or `libexec/`), symlinks resolved. The package therefore works
from wherever it is unpacked, aqua's versioned package directory included,
reads its own `ssh_config` and never Apple's, and spawns its own helpers.
`scp` and `sftp` execute the package's `ssh`, and `ssh-agent` finds the sk
helper, without an environment variable.

The patch touches twelve client-side files and is applied only to the exact
sources it was written against (`patches/relocate.sha256`): an OpenSSH bump
that moves one of those sites fails the build, so the patch is re-read, never
silently half-applied.
The patch is under OpenSSH's BSD-style terms (OpenSSH's `LICENCE`), not
this repository's MIT.
Where the package stands against OpenSSH portable, the release it builds and
what it changes, is [`UPSTREAM.md`](./UPSTREAM.md).

## Installing

Through aqua, as a `github_release` package. The reference registry entry:

```yaml
- type: github_release
  repo_owner: forkcloser
  repo_name: openssh
  description: OpenSSH with security keys built in, relocatable, darwin/arm64 (forkcloser/openssh)
  asset: openssh_{{trimV .Version}}_{{.OS}}_{{.Arch}}.tar.gz
  format: tar.gz
  files:
    - name: ssh
      src: openssh_{{trimV .Version}}_{{.OS}}_{{.Arch}}/bin/ssh
    - name: ssh-agent
      src: openssh_{{trimV .Version}}_{{.OS}}_{{.Arch}}/bin/ssh-agent
    - name: ssh-add
      src: openssh_{{trimV .Version}}_{{.OS}}_{{.Arch}}/bin/ssh-add
    - name: ssh-keygen
      src: openssh_{{trimV .Version}}_{{.OS}}_{{.Arch}}/bin/ssh-keygen
    - name: ssh-keyscan
      src: openssh_{{trimV .Version}}_{{.OS}}_{{.Arch}}/bin/ssh-keyscan
    - name: scp
      src: openssh_{{trimV .Version}}_{{.OS}}_{{.Arch}}/bin/scp
    - name: sftp
      src: openssh_{{trimV .Version}}_{{.OS}}_{{.Arch}}/bin/sftp
    - name: ssh-agent-install
      src: openssh_{{trimV .Version}}_{{.OS}}_{{.Arch}}/bin/ssh-agent-install
  checksum:
    type: github_release
    asset: checksums.txt
    algorithm: sha256
  github_artifact_attestations:
    signer_workflow: forkcloser/openssh/.github/workflows/release.yaml
  supported_envs:
    - darwin/arm64
```

The release publishes a GitHub Artifact Attestation for every asset, so a
consumer verifies it (`github_artifact_attestations`) and pins the checksum
(`checksum`) both. aqua's `bin/` then holds a proxy per file above; each
resolves to the pinned version at every call, and the binaries find their
package through their real path.

## The agent

```bash
ssh-agent-install              # ~/Library/LaunchAgents/org.forkcloser.ssh_agent.plist, started
ssh-agent-install uninstall    # stop and remove; GUI applications have no agent until the next login
```

Shells take `SSH_AUTH_SOCK` from `~/.ssh/org.forkcloser.agent.env`, which
the launch script writes at every start of the agent (mode 0600, one
`export` line naming the socket it serves), so a socket renamed by an
upgrade is invisible to them. The installer makes every rc it knows source
that file, `~/.zshrc`, `~/.bashrc` and `~/.profile`, each once, guarded so a
shell started before the agent's first run does not complain, and says so:
open a new shell or source the file. An rc carrying the fixed `export` of an
earlier install has it replaced. `uninstall` removes the lines and the file.

The agent listens on `~/.ssh/org.forkcloser.agent.sock`, foreground under
launchd, restarted by it. The plist points at the launch script by the
package's own path, since launchd starts it with HOME and the system PATH
only, nothing a tool manager's proxy could resolve itself with; after an
upgrade to a new package directory, run `ssh-agent-install` again. The
launch script execs the `ssh-agent` beside it, and sets `SSH_AUTH_SOCK` in
the login session's environment too (`launchctl setenv`, at every start,
since it lasts a login): that is where GUI applications started from the
Dock or Spotlight take theirs, and launchd's own value points at Apple's
agent. An application already running keeps the value it started with until
relaunched.

Apple's agent is left alone: it listens on its own socket and only ever runs
when a client connects there, which nothing does once `SSH_AUTH_SOCK` is
ours. To retire it anyway, as the user:

```bash
launchctl disable gui/$(id -u)/com.openssh.ssh-agent   # from the next login; SIP refuses bootout and kill
launchctl enable gui/$(id -u)/com.openssh.ssh-agent    # undo, from the next login
```

## The server

Off by default: nothing listens until you say so. `sshd-install` runs the
package's `sshd` as a user LaunchAgent, `org.forkcloser.sshd`, as you, never
as root:

```bash
sshd-install      # host key made once, config tested, server loaded on port 22; prints the fingerprint
sshd-uninstall    # server unloaded; the host key stays
```

What that means:

- **Sessions are yours only.** The server authenticates with your
  `~/.ssh/authorized_keys` and logs in your account; no other user, no root,
  no password, no keyboard-interactive (`etc/ssh/sshd_config`, the hardened
  set with the client's algorithm lists). No privilege separation user or
  chroot is needed below root.
- **Port 22, no sudo.** macOS lets a user bind port 22 on the any-address
  (`0.0.0.0` and `::`), and refuses a specific address; the shipped config
  binds the any-address for that reason.
- **The host key** lives under `${XDG_STATE_HOME:-~/.local/state}/org.forkcloser.sshd/`,
  outside the package directory, so a package update keeps the server's
  identity; `sshd-install` after an update moves the server onto the new
  package path. Logs: `~/Library/Logs/org.forkcloser.sshd/sshd.log`.
- **TCC.** A session runs with the server's privacy permissions: to read
  Desktop, Documents, Downloads or other protected folders over ssh, grant
  the package's `sbin/sshd` Full Disk Access once (System Settings, Privacy &
  Security). Touch ID for `sudo` does not work over ssh.
- **Remote Login off.** Apple's server (System Settings, General, Sharing)
  holds port 22 when it is on; `sshd-install` refuses to install beside it.
- The macOS application firewall may ask once whether `sshd` accepts
  incoming connections.

## Releasing

Tag `v<major>.<minor>.<p>` for OpenSSH `<major>.<minor>p<p>`: `v10.6.1` for
10.6p1. A rebuild without an upstream bump (a library bump, a patch) is
`v10.6.1.1`, `v10.6.1.2`: a fourth segment, never a `-suffix`, since semver
sorts `X.Y.Z-1` *before* `X.Y.Z`. `build.sh` refuses a tag that does not name
the pinned OpenSSH. The release workflow builds and smoke-tests the package,
attests every asset and publishes with a `checksums.txt`; a
`workflow_dispatch` run is the dry run (builds, publishes nothing).

The asset is `openssh_<version>_darwin_arm64.tar.gz`, unpacking to
`openssh_<version>_darwin_arm64/{bin,libexec,etc/ssh,share}`, with the
licenses of everything linked in under `share/licenses`.

## Version bumps

Every source is a `pins.yaml` entry: OpenSSH from OpenBSD's CDN (watched
through its directory index), libfido2, libcbor and LibreSSL from GitHub.
Renovate proposes each bump alone, the checksum workflow brings the digest
along (`limen pins refresh`), and CI builds and smoke-tests the result on
every PR, so a bump can only go green on a source that downloads, verifies
and builds. Merging and tagging stay human acts.

## Building

```bash
just build   # build/dist/openssh_<version>_darwin_arm64.tar.gz (macOS arm64 only)
just test    # the smoke test, on the package relocated to a temp dir
```

`just build` reads `pins.yaml`, downloads and verifies the four sources,
builds LibreSSL, libcbor and libfido2 static, applies the relocation patch
under its guard, configures and builds OpenSSH against the static LibreSSL,
keeps the client set, writes the configuration and the agent files, signs
each binary ad hoc under its name, and packages. CMake comes from aqua;
the compiler, the SDK's libedit and zlib are Xcode's; no pkg-config is used
(libfido2 is pointed at the libraries by directory).
