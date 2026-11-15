# Upstream

Repackaging of [OpenSSH portable](https://www.openssh.com/portable.html), released on
OpenBSD's CDN, built for macOS as one relocatable package.

- Built from: openssh-10.6p2 (`pins.yaml`, the tarball verified by sha256)
- Reviewed through: 10.6p2, re-read 2026-11-14. Of the sixteen files relocate.patch touches,
  10.6p2 changes two: misc.c (`mkdir_path` skips an empty path component, two lines added above
  the patch's hunk, which moves down by them) and servconf.c (the test of the GatewayPorts
  warning, at line 283, where the nearest hunk is at 343). Neither touches a line the patch
  changes or reads; readconf.c, the one file include-env.patch touches, and ssh-agent.c, the one
  agent-log.patch touches, are the same files. A bump re-reads the patches below against the new
  sources, since `patches/relocate.sha256` holds the sixteen files relocate.patch was written
  for, readconf.c and ssh-agent.c among them, and a bump that touches one fails the build before
  any patch applies

The agent, the server's launchd units, the installers and the package layout are this
repository's own additions, described in the README; they change nothing of upstream's
code. What does is below.

## Changes upstream does not have

| Change | Where | Here |
| --- | --- | --- |
| Paths resolve from the running executable, `<prefix>/etc/ssh` and `<prefix>/libexec`, instead of compile-time paths, so the package runs from wherever it is unpacked and reads its own `ssh_config` | `patches/relocate.patch`, sixteen files, twelve of them the client's | https://github.com/forkcloser/openssh/pull/33 |
| `ssh` refuses to run when its package's `ssh_config` is missing (a binary copied out of its tree), where upstream reads a missing system configuration as an empty one and runs on the compiled-in defaults; `-F` names another | `patches/relocate.patch`, ssh.c | https://github.com/forkcloser/openssh/pull/118 |
| An `Include` naming an unset environment variable is skipped at debug level, where upstream logs two error lines on every run; the shipped `ssh_config` reads the file `SSH_CONFIG_INCLUDE` names ahead of its defaults, when set | `patches/include-env.patch`, one file, readconf.c | https://github.com/forkcloser/openssh/pull/73 |
| `ssh-agent` logs every sign request at INFO, given or refused: the time, the key, for a login the bound session's host key and the user, and the pid, cdhash and executable path of the process that last used the connection when the request was read (the audit token `LOCAL_PEERTOKEN` gives then). Upstream logs a refusal's reason and nothing of a signature it gives. macOS only | `patches/agent-log.patch`, one file, ssh-agent.c | https://github.com/forkcloser/openssh/pull/125 |
| Built against LibreSSL's libcrypto and libfido2, both static, without OpenSSL; every binary signed by its name | `build.sh` | https://github.com/forkcloser/openssh/pull/33, https://github.com/forkcloser/openssh/pull/40 |
