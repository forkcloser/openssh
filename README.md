# openssh

OpenSSH for macOS with security keys built in, as one relocatable package for
the toolchain, installed and pinned through aqua like everything
else. Exists because Apple's OpenSSH is built without FIDO support, so an
`sk-ssh-ed25519@openssh.com` key (a YubiKey, a Secure Enclave through a
provider) is unusable with the system `ssh`, `ssh-agent` and `ssh-keygen`.

What the package is:

- **OpenSSH portable**: the client set (`ssh`, `ssh-agent`, `ssh-add`,
  `ssh-keygen`, `scp`, `sftp`, `ssh-keyscan`, the `ssh-sk-helper` they spawn
  and the `ssh-pkcs11-helper` the agent spawns) and the server (`sshd` with
  its two helpers), the server off by default and user-scoped when on.
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
  system and nothing else: libSystem, libz, libresolv, CoreFoundation and
  IOKit in every one, libedit and libncurses in `sftp`, libsandbox in `sshd`
  and its two helpers. The list is `config/system-libraries`; `build.sh`
  refuses a library it does not name.
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
- **A Developer ID signature** on every released binary, hardened runtime on
  and timestamped, under a stable identifier: `org.forkcloser.ssh`,
  `org.forkcloser.ssh-keygen` and so on, where the linker's own ad-hoc
  signature carries the file name. An agent's peer check (taciturn's) binds a
  binary by code requirement, anchor apple generic, the team's OU and that
  identifier; the cdhash in the agent's log identifies the build that asked.
  A local build is ad hoc signed under the same identifiers, which proves no
  origin. The hardened runtime's library validation is turned off, by
  entitlement, on the four binaries that load a library a user names, `ssh`
  and `ssh-keygen` (a PKCS#11 provider, in-process), `ssh-pkcs11-helper` (the
  same, for the agent) and `ssh-sk-helper` (a security-key middleware); the
  rest of the hardened runtime stays on all of them. Not notarized: hermetic's
  download carries no quarantine attribute, so Gatekeeper is not in the path.

darwin/arm64 only, macOS 15.0 and later: the binaries are built for that
system and an earlier one refuses to load them. Intel Mac support was
dropped, and Linux has distribution packages with FIDO support.

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

The configuration is the package's, so `ssh` does not run without it: a
binary copied out of its tree finds no `etc/ssh` above it and stops, saying
so, where OpenSSH would run on its compiled-in defaults, RSA included, in
silence. `-F` names another configuration, and is the way to run one on
purpose.

The patch touches twelve client-side files and is applied only to the exact
sources it was written against (`patches/relocate.sha256`): an OpenSSH bump
that moves one of those sites fails the build, so the patch is re-read, never
silently half-applied. A second patch (`patches/include-env.patch`) makes an
`Include` that names an unset environment variable nothing, where OpenSSH
complains of it on every run; the shipped `ssh_config` uses it to read an
extra client configuration named by `SSH_CONFIG_INCLUDE` ahead of its defaults, when set.
The variable holds a path as it is: a `~` the shell did not expand (a value
quoted, or set in a launchd plist) is refused by OpenSSH, which takes no
tilde in a system configuration's `Include`, and every `ssh` then stops with
"bad include path", as it does on a file it cannot read.
A third (`patches/agent-log.patch`) makes the agent log every sign request,
described under [The agent](#the-agent); it changes ssh-agent.c, one of the
files the guard holds.
The three patches are under OpenSSH's BSD-style terms (OpenSSH's `LICENCE`),
not this repository's MIT.
Where the package stands against OpenSSH portable, the release it builds and
what it changes, is [`UPSTREAM.md`](./UPSTREAM.md).

## Installing

Through aqua, as a `github_release` package. The reference registry entry:

```yaml
- type: github_release
  repo_owner: packcloser
  repo_name: openssh
  description: OpenSSH with security keys built in, relocatable, darwin/arm64 (packcloser/openssh)
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
    - name: sshd-install
      src: openssh_{{trimV .Version}}_{{.OS}}_{{.Arch}}/bin/sshd-install
    - name: sshd-uninstall
      src: openssh_{{trimV .Version}}_{{.OS}}_{{.Arch}}/bin/sshd-uninstall
  checksum:
    type: github_release
    asset: checksums.txt
    algorithm: sha256
  github_artifact_attestations:
    signer_workflow: farcloser/limen/.github/workflows/limen-release-apple.yaml
  supported_envs:
    - darwin/arm64
```

The release publishes a GitHub Artifact Attestation for every asset, so a
consumer verifies it (`github_artifact_attestations`) and pins the checksum
(`checksum`) both. The signer is limen's Apple release lane, the reusable
workflow this repository's `release.yaml` calls: an attestation names the
reusable workflow as its signer and the calling repository in its extensions.
aqua's `bin/` then holds a proxy per file above; each resolves to the pinned
version at every call, and the binaries find their package through their real
path.

### Verifying a release

The attestation's signer is the lane, not this repository, so `gh
attestation verify` needs the signer named; with `--repo` alone it fails.
The same command covers the archive, its SBOM and `checksums.txt`:

```sh
gh attestation verify openssh_<version>_darwin_arm64.tar.gz --repo packcloser/openssh \
  --signer-workflow farcloser/limen/.github/workflows/limen-release-apple.yaml
```

Releases up to `v10.6.2.1` were cut when this repository was
`forkcloser/openssh` and name it as the calling repository: for those, name
`forkcloser/openssh` in the command above and in the one below.

The keyless signature over `checksums.txt`, for a verifier with cosign and
no `gh`; the identity is the lane at the commit the release called, the
calling repository is an extension of the certificate:

```sh
cosign verify-blob checksums.txt --bundle checksums.txt.sigstore.json \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/farcloser/limen/\.github/workflows/limen-release-apple\.yaml@' \
  --certificate-github-workflow-repository packcloser/openssh
sha256sum -c checksums.txt
```

Every binary in the archive is signed with the Developer ID, hardened
runtime, timestamped, identified as `org.forkcloser.<name>`:

```sh
codesign -dvv bin/ssh
codesign -d --entitlements - bin/ssh
```

`ssh`, `ssh-keygen`, `ssh-pkcs11-helper` and `ssh-sk-helper` carry
`com.apple.security.cs.disable-library-validation`, since they load a
PKCS#11 provider or a security-key middleware the user names; the others
carry no entitlement. None is notarized: aqua's download, like `curl` and
`tar`, sets no quarantine attribute, so Gatekeeper never consults a
notarization for these. A copy saved with a browser does carry the
attribute, and is refused at its first run until `xattr -d
com.apple.quarantine` removes it.

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
open a new shell or source the file. A `~/.bash_profile` or `~/.bash_login`
that exists gets the line as well, since a bash login shell that finds one
reads neither `~/.profile` nor `~/.bashrc`; neither is created. An rc
carrying the fixed `export` of an earlier install has it replaced.
`uninstall` removes the lines and the file.
An rc the installer cannot write, of mode 0444 or linked into a read-only store, does not
stop it: the agent is installed, the other files are written, and the closing line names the
one that was not, with the line to add there by hand.

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

The agent writes one line for every signature it is asked for, given or
refused, to `~/Library/Logs/org.forkcloser.ssh_agent/stderr.log`, where
OpenSSH's agent records nothing of a signature it gives
(`patches/agent-log.patch`):

```text
sign ok at 2026-11-15T19:34:03Z key ED25519 SHA256:… to hostkey ED25519 SHA256:… user git by pid 4242 cdhash 3f2a… path /…/bin/ssh
sign ok at 2026-11-15T19:35:10Z key ED25519 SHA256:… to - (not a login) by pid 4250 cdhash 91c0… path /usr/bin/ssh-keygen
sign refused at 2026-11-15T19:36:41Z key ED25519 SHA256:… to forwarded hostkey ED25519 SHA256:… user root by pid 4261 cdhash 3f2a… path /…/bin/ssh
```

- **The time**, in UTC.
- **The key**, by type and fingerprint: `ssh-add -l` gives the same.
- **The destination** of a login is the server's host key, since the agent
  is never told a host name: `ssh-keygen -lf ~/.ssh/known_hosts` lists the
  fingerprints by name. `forwarded` says the request came through an agent
  forwarded from another host; `hostkey -` that the client bound no session
  (an ssh older than OpenSSH 8.9). The user is the one asked for on the
  server, cut at 64 bytes with `...`. A signature that is not a login, a
  file or a commit signed with `ssh-keygen -Y sign`, has neither.
- **The process**, after `by`: its pid, the cdhash of its code signature
  (`-` where it has none) and the path of its executable, the three of one
  process. The cdhash is the code itself, whatever path it was run from:
  `codesign -d -vvv <file>` prints a file's. What started that process (git,
  an editor, a script) the agent does not know.
- A byte the peer chose that would break a line, in a path or a user name,
  is written `%XX`. A line is cut at about a thousand bytes, which only a
  very long path reaches: the path is last, so nothing else is lost.
- Each line ends with a carriage return before its newline, as every line
  OpenSSH writes to stderr does: a pattern anchored on the line's end has to
  allow for it.

The process named is the one that last used the connection when the agent
read the request, which is all macOS tells the far end of a socket: it keeps
no record of who opened one. For an ssh that connects and asks, that is the
ssh. It is not proof against the account itself: a program running as the
account can share a connection with another program and arrange which of
the two is named, as it can write to the log file. The log says what the
account's own tools did, and shows a program that is not one of them using
a key; it does not bind a program determined to be mistaken for another.

The log is a record of the hosts and accounts this account signs in to, kept
on disk. Its directory is the account's alone, which the installer makes it
(mode 0700): the account and root read it. The launch script
sets it aside as `stderr.log.1` when it is past 4 MB at the agent's start,
replacing the one before, so the two hold 8 MB at most plus what one run of
the agent adds.

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
- **Nothing is forwarded.** A session is a shell or sftp. The server refuses
  a client's `-L` and `-R` (a TCP port or a unix socket), `-D`, `-A`, `-X`
  and `-w`. That is this package's choice (`DisableForwarding yes` in
  `etc/ssh/sshd_config`), not upstream's default, which allows TCP,
  unix-socket and agent forwarding. The server reads that one file, which
  has no `Include`, so there is no supported override.
- **Port 22, no sudo.** macOS lets a user bind port 22 on the any-address
  (`0.0.0.0` and `::`), and refuses a specific address; the shipped config
  binds the any-address for that reason.
- **The host key** lives under `${XDG_STATE_HOME:-~/.local/state}/org.forkcloser.sshd/`,
  outside the package directory, so a package update keeps the server's
  identity; `sshd-install` after an update moves the server onto the new
  package path.
- **The log** is `~/Library/Logs/org.forkcloser.sshd/sshd.log`: every
  connection to port 22, a login or a scan, at `LogLevel INFO`. Nothing
  bounds it while the server runs. `sshd-install`, which is run again at
  every package update, sets it aside as `sshd.log.1` when it is past 4 MB,
  replacing the one before. Between two runs, every process that writes it
  opens it for appending, so `: > ~/Library/Logs/org.forkcloser.sshd/sshd.log`
  empties it under a running server; a rename sets it aside for the
  connections that follow, each of which opens the file itself.
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
the pinned OpenSSH. `just do release vX.Y.Z` creates the signed tag and pushes
it; the push runs limen's Apple release lane (`limen-release-apple.yaml`,
limen's `book/releasing.md`). Its sign job, in the `release` environment that
holds the Developer ID certificate and waits for the owner's approval, runs
`just package <version>`: `build.sh` signs every binary with that identity,
the smoke test runs on the relocated package, and the archive lands under
`.build/assets/` with its SBOM. Its publish job holds no Apple secret: `just
do release --ci` runs `verify-assets` on what arrived, writes `checksums.txt`,
signs it keyless and publishes, and the build provenance attestation covers
every asset. A local dry run is `just package 10.6.1` then
`PACKAGE_VERSION=10.6.1 just do release --local --dry-run`: ad hoc signed,
nothing published.

The asset is `openssh_<version>_darwin_arm64.tar.gz`, unpacking to
`openssh_<version>_darwin_arm64/{bin,sbin,libexec,etc/ssh,share}`, with the
licenses of everything linked in under `share/licenses`: each project's own
file (OpenSSH, LibreSSL, libfido2, libcbor) and `NOTICES`, which `notices.sh`
takes from the sources themselves, one of each notice their comments state. A
project's file is its summary and can be short of what its sources ask to be
reproduced; a source whose terms the script does not know, or a line of one
that states a copyright the script did not read into a notice, stops the build. One source names its
author and no terms: they are written out in `config/notices`.

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
builds LibreSSL, libcbor and libfido2 static, applies the three patches
under the relocation patch's guard, configures and builds OpenSSH against the static LibreSSL,
keeps the client set, writes the configuration and the agent files, signs each
binary under its name (Developer ID with the hardened runtime when the release
lane exports `APPLE_SIGN_IDENTITY`, ad hoc otherwise), and packages. CMake
comes from aqua; the compiler, the SDK's libedit and zlib are Xcode's; no
pkg-config is used (libfido2 is pointed at the libraries by directory).
