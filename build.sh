#!/usr/bin/env bash
#
# Build the OpenSSH client set for macOS arm64 with built-in FIDO support:
# OpenSSH portable without OpenSSL, libfido2 and libcbor linked statically,
# LibreSSL's libcrypto statically under libfido2 only, Apple's clang, the SDK's
# libedit and zlib. Every source is a pins.yaml entry, read back with
# `limen pins get` and verified against its sha256 before it is unpacked.
#
# The relocation patch makes the binaries find their configuration directory
# and helpers under the prefix they run from (bin/.. or libexec/..), so the
# package unpacks anywhere; it is applied only to the exact files it was
# written against (patches/relocate.sha256), so an OpenSSH bump that moves a
# site fails here, not at run time.
#
# Output: build/dist/openssh_<version>_darwin_arm64.tar.gz, where <version>
# is the tag's (PACKAGE_VERSION, e.g. 10.6.1 or 10.6.1.2) or, by default, the
# pinned OpenSSH version with its portable level as the third segment.

set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
cd "${root}"

[ "$(uname -s)-$(uname -m)" = 'Darwin-arm64' ] || { echo "this build runs on macOS arm64 only" >&2; exit 1; }

work="${WORK:-${root}/build}"
deps="${work}/deps"
stage="${work}/stage"
dist="${work}/dist"
jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# pin <name> <field>: one value of a pins.yaml entry (version, url, sha256).
pin() {
  limen pins get "$1" "$2"
}

# fetch <pin>: download the pin's url once into the work dir, verify against
# the pin's sha256 always. Prints the file's path.
fetch() {
  local name="$1" url sum file
  url="$(pin "${name}" url)"
  sum="$(pin "${name}" sha256)"
  file="${work}/dl/${name}-$(pin "${name}" version).tar.gz"
  mkdir -p "${work}/dl"
  if [ ! -f "${file}" ]; then
    echo "fetching ${name}" >&2
    curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-delay 3 -o "${file}.part" "${url}"
    mv "${file}.part" "${file}"
  fi
  echo "${sum}  ${file}" | sha256sum -c - > /dev/null || {
    echo "${name}: sha256 mismatch against pins.yaml" >&2
    rm -f "${file}"
    exit 1
  }
  echo "${file}"
}

# unpack <pin> <dir>: a fresh tree of the pin's archive at <dir>.
unpack() {
  local file dir="$2"
  file="$(fetch "$1")"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  tar -xzf "${file}" -C "${dir}" --strip-components=1
}

openssh_version="$(pin openssh version)"
package_version="${PACKAGE_VERSION:-${openssh_version/p/.}}"
# The tag names the OpenSSH it packages: its first three segments are the
# pinned version's, a fourth is a rebuild (10.6.1.2).
[ "${package_version%.*.*.*}" = "${package_version}" ] && [ "${package_version#"${openssh_version/p/.}"}" = "" ] ||
  [ "${package_version%.*}" = "${openssh_version/p/.}" ] ||
  { echo "PACKAGE_VERSION ${package_version} is not the pinned OpenSSH ${openssh_version} (${openssh_version/p/.} or ${openssh_version/p/.}.N)" >&2; exit 1; }

export MACOSX_DEPLOYMENT_TARGET=15.0
export CC=clang
# __FILE__ in a static library (LibreSSL's assertion sites) and in OpenSSH is
# the path the compiler was given: mapped to a relative one, so no build
# directory lands in a binary and the smoke test can refuse one that does.
prefix_map="-ffile-prefix-map=${work}=."
# The compile-time prefix OpenSSH bakes where the relocation patch does not
# reach (the host key files of hostbased authentication, which the shipped
# config refuses, and the remote command's default PATH): a fixed path that
# exists nowhere, never the build tree. The stage receives the files through
# DESTDIR and is flattened after.
install_prefix="/opt/forkcloser/openssh"

# cmake_static <src> <build> [options...]: a static, release build of a cmake
# project installed into the deps prefix. The build directory is not named
# "build": libcbor ships a Bazel BUILD file, which collides with it on a
# case-insensitive filesystem.
cmake_static() {
  local src="$1" bld="$2"
  shift 2
  cmake -S "${src}" -B "${bld}" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_C_FLAGS="${prefix_map}" \
    -DCMAKE_INSTALL_PREFIX="${deps}" -DCMAKE_INSTALL_LIBDIR=lib "$@" > "${bld}.log" 2>&1 ||
    { tail -n 30 "${bld}.log" >&2; exit 1; }
  cmake --build "${bld}" -j "${jobs}" >> "${bld}.log" 2>&1 || { tail -n 30 "${bld}.log" >&2; exit 1; }
  cmake --install "${bld}" >> "${bld}.log" 2>&1
}

rm -rf "${deps}" "${stage}"
mkdir -p "${deps}" "${stage}" "${dist}"

echo "libressl $(pin libressl version): libcrypto for libfido2"
unpack libressl "${work}/src/libressl"
cmake_static "${work}/src/libressl" "${work}/src/libressl/cmake-build" -DLIBRESSL_APPS=OFF -DLIBRESSL_TESTS=OFF

echo "libcbor $(pin libcbor version)"
unpack libcbor "${work}/src/libcbor"
cmake_static "${work}/src/libcbor" "${work}/src/libcbor/cmake-build" -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF

echo "libfido2 $(pin libfido2 version)"
unpack libfido2 "${work}/src/libfido2"
# libfido2 looks its libraries up through pkg-config, which the hermetic PATH
# does not carry, and CMake would otherwise find a Homebrew one by prefix on
# the runner and take whatever it knows. A pkg-config that answers nothing
# (/usr/bin/false) keeps the search ours: the header probes run with the deps
# on the include path, the libraries come from the deps by directory, and
# zlib is the SDK's, which has no .pc to find.
cmake_static "${work}/src/libfido2" "${work}/src/libfido2/cmake-build" -DBUILD_STATIC_LIBS=ON \
  -DBUILD_EXAMPLES=OFF -DBUILD_TOOLS=OFF -DBUILD_MANPAGES=OFF \
  -DPKG_CONFIG_EXECUTABLE=/usr/bin/false -DCMAKE_REQUIRED_INCLUDES="${deps}/include" \
  -DCRYPTO_INCLUDE_DIRS="${deps}/include" -DCRYPTO_LIBRARY_DIRS="${deps}/lib" \
  -DCBOR_INCLUDE_DIRS="${deps}/include" -DCBOR_LIBRARY_DIRS="${deps}/lib" \
  -DZLIB_FOUND=ON -DZLIB_LIBRARIES=z

echo "openssh ${openssh_version}"
src="${work}/src/openssh"
unpack openssh "${src}"

# The relocation patch, only on the files it was written against: the sixteen
# it touches, hashed in the order patches/relocate.sha256 records.
patched=(misc.c misc.h readconf.c readpass.c scp.c servconf.c sftp.c ssh-add.c ssh-agent.c ssh-pkcs11-client.c ssh-sk-client.c ssh.c sshconnect2.c sshd-auth.c sshd-session.c sshd.c)
expected="$(cat "${root}/patches/relocate.sha256")"
actual="$(cd "${src}" && cat "${patched[@]}" | sha256sum | cut -d' ' -f1)"
[ "${actual}" = "${expected}" ] || {
  echo "openssh ${openssh_version}: not the sources patches/relocate.patch was written against (sha256 ${actual}); recheck the patch for this OpenSSH" >&2
  exit 1
}
# POSIX options only: -p1 for the a/ b/ prefixes, -N to refuse a patch
# already applied.
(cd "${src}" && patch -p1 -N) < "${root}/patches/relocate.patch" > /dev/null
grep -q 'reloc_path' "${src}/misc.c" || { echo "relocate.patch did not apply" >&2; exit 1; }

# pkg-config is not on the hermetic PATH, and configure then takes libfido2 and
# libedit by header and library; the static libfido2 needs its own
# dependencies named, which LIBS carries to every link. The prefix and
# sysconfdir are the inert fixed ones: the patch resolves the paths that
# matter at run time, and the files are installed into the stage by DESTDIR.
(
  cd "${src}"
  CFLAGS="-O2 ${prefix_map}" \
  CPPFLAGS="-I${deps}/include -D__APPLE_SANDBOX_NAMED_EXTERNAL__" \
  LDFLAGS="-L${deps}/lib" \
  LIBS="-lcbor -lcrypto -lz -framework CoreFoundation -framework IOKit" \
  PKG_CONFIG=false \
  ./configure --prefix="${install_prefix}" --sysconfdir="${install_prefix}/etc/ssh" \
    --without-openssl --with-security-key-builtin --with-libedit --without-pam \
    > configure.log 2>&1 || { tail -n 30 configure.log >&2; exit 1; }
  grep -q 'Compiler: clang' configure.log || { echo "configure did not pick clang" >&2; exit 1; }
  make -j "${jobs}" > make.log 2>&1 || { tail -n 30 make.log >&2; exit 1; }
  make install-nokeys DESTDIR="${stage}" > install.log 2>&1 || { tail -n 30 install.log >&2; exit 1; }
)
mv "${stage}${install_prefix}"/* "${stage}/"
rm -rf "${stage:?}/opt"

# The client set and the server (sshd, its two helpers, sftp-server, the
# moduli). ssh-keysign (hostbased authentication, which both shipped configs
# refuse) and the man pages leave; our configs replace the generated ones.
rm -rf "${stage:?}/share" "${stage:?}/var" "${stage}/libexec/ssh-keysign"
install -m 0644 "${root}/config/ssh_config" "${stage}/etc/ssh/ssh_config"
install -m 0644 "${root}/config/sshd_config" "${stage}/etc/ssh/sshd_config"

# The agent and the server as LaunchAgents: launch script, plists, installers.
install -m 0755 "${root}/agent/ssh-agent-launchd" "${stage}/libexec/ssh-agent-launchd"
install -m 0755 "${root}/agent/ssh-agent-install" "${stage}/bin/ssh-agent-install"
install -m 0755 "${root}/agent/sshd-install" "${stage}/bin/sshd-install"
install -m 0755 "${root}/agent/sshd-uninstall" "${stage}/bin/sshd-uninstall"
mkdir -p "${stage}/share/forkcloser"
install -m 0644 "${root}/agent/org.forkcloser.ssh_agent.plist" "${stage}/share/forkcloser/org.forkcloser.ssh_agent.plist"
install -m 0644 "${root}/agent/org.forkcloser.sshd.plist" "${stage}/share/forkcloser/org.forkcloser.sshd.plist"

# Licenses of everything linked in.
mkdir -p "${stage}/share/licenses"
install -m 0644 "${src}/LICENCE" "${stage}/share/licenses/openssh"
install -m 0644 "${work}/src/libfido2/LICENSE" "${stage}/share/licenses/libfido2"
install -m 0644 "${work}/src/libcbor/LICENSE.md" "${stage}/share/licenses/libcbor"
install -m 0644 "${work}/src/libressl/COPYING" "${stage}/share/licenses/libressl"

# Every binary links the system only: a path into the build tree is a static
# library that did not get linked in, or a dylib that leaked.
for bin in "${stage}"/bin/* "${stage}"/sbin/* "${stage}"/libexec/*; do
  case "$(file -b "${bin}")" in
    *Mach-O*)
      otool -L "${bin}" | sed 1d | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/Library/Frameworks/)' && {
        echo "${bin##*/} links outside the system" >&2
        exit 1
      }
      ;;
    *) ;;
  esac
done

name="openssh_${package_version}_darwin_arm64"
rm -rf "${work:?}/${name}"
mv "${stage}" "${work}/${name}"
tar -czf "${dist}/${name}.tar.gz" -C "${work}" "${name}"
mv "${work}/${name}" "${stage}"
echo "✓ ${dist}/${name}.tar.gz"
