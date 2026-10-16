# Upstream

Repackaging of [OpenSSH portable](https://www.openssh.com/portable.html), released on
OpenBSD's CDN, built for macOS as one relocatable package.

- Built from: openssh-10.6p1 (`pins.yaml`, the tarball verified by sha256)
- Reviewed through: 10.6p1; a bump re-reads the patch below against the new sources, since
  `patches/relocate.sha256` holds the patch to the exact files it was written for

The agent, the server's launchd units, the installers and the package layout are this
repository's own additions, described in the README; they change nothing of upstream's
code. What does is below.

## Changes upstream does not have

| Change | Where | Here |
| --- | --- | --- |
| Paths resolve from the running executable, `<prefix>/etc/ssh` and `<prefix>/libexec`, instead of compile-time paths, so the package runs from wherever it is unpacked and reads its own `ssh_config` | `patches/relocate.patch`, sixteen files, twelve of them the client's | https://github.com/forkcloser/openssh/pull/33 |
| Built against LibreSSL's libcrypto and libfido2, both static, without OpenSSL; every binary signed by its name | `build.sh` | https://github.com/forkcloser/openssh/pull/33, https://github.com/forkcloser/openssh/pull/40 |
