# Upstream

Repackaging of [OpenSSH portable](https://www.openssh.com/portable.html), released on
OpenBSD's CDN, built for macOS as one relocatable package.

- Built from: openssh-10.6p1 (`pins.yaml`, the tarball verified by sha256)
- Reviewed through: 10.6p1; a bump re-reads the patches below against the new sources, since
  `patches/relocate.sha256` holds the sixteen files relocate.patch was written for, readconf.c
  among them, and a bump that touches one fails the build before either patch applies

The agent, the server's launchd units, the installers and the package layout are this
repository's own additions, described in the README; they change nothing of upstream's
code. What does is below.

## Changes upstream does not have

| Change | Where | Here |
| --- | --- | --- |
| Paths resolve from the running executable, `<prefix>/etc/ssh` and `<prefix>/libexec`, instead of compile-time paths, so the package runs from wherever it is unpacked and reads its own `ssh_config` | `patches/relocate.patch`, sixteen files, twelve of them the client's | https://github.com/forkcloser/openssh/pull/33 |
| An `Include` naming an unset environment variable is skipped at debug level, where upstream logs two error lines on every run; the shipped `ssh_config` reads the file `SSH_CONFIG_INCLUDE` names ahead of its defaults, when set | `patches/include-env.patch`, one file, readconf.c | https://github.com/forkcloser/openssh/pull/73 |
| Built against LibreSSL's libcrypto and libfido2, both static, without OpenSSL; every binary signed by its name | `build.sh` | https://github.com/forkcloser/openssh/pull/33, https://github.com/forkcloser/openssh/pull/40 |
