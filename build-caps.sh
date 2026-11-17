#!/usr/bin/env bash
#
# The caps every build step runs under, so that a build never takes the whole
# machine it runs on: sourced by build.sh, which runs make and cmake through
# the functions below and never by name.
#
#   BUILD_JOBS     parallel jobs of one make or cmake build (default 4)
#   BUILD_TIMEOUT  wall clock of one step, as timeout(1) takes it (default 30m)
#
# Nothing here caps memory: macOS has no limit a process can be held to. The
# job count is what bounds it.
#
#   build-caps.sh --test  runs this file's own test

build_jobs="${BUILD_JOBS:-4}"
build_timeout="${BUILD_TIMEOUT:-30m}"
case "${build_jobs}" in
  '' | *[!0-9]* | 0*)
    echo "BUILD_JOBS must be a whole number above 0, not '${build_jobs}'" >&2
    # Sourced or run, either way the build stops here.
    # shellcheck disable=SC2317 # exit is reached when the file is run
    return 2 2> /dev/null || exit 2
    ;;
  *) ;;
esac

# capped <command...>: the command, stopped when it outlasts BUILD_TIMEOUT.
# timeout is the pinned coreutils': it signals the command's whole process
# group, so a make's compilers go with it.
capped() {
  local status=0
  timeout "${build_timeout}" "$@" || status=$?
  [ "${status}" -ne 124 ] || echo "build-caps: stopped after ${build_timeout} (BUILD_TIMEOUT): $*" >&2
  return "${status}"
}

# capped_make [arguments...]: make, at BUILD_JOBS.
capped_make() {
  capped make -j "${build_jobs}" "$@"
}

# capped_cmake_build <build directory>: cmake --build, at BUILD_JOBS.
capped_cmake_build() {
  capped cmake --build "$1" -j "${build_jobs}"
}

[ "${1:-}" = '--test' ] && [ "${BASH_SOURCE[0]}" = "$0" ] || return 0 2> /dev/null || exit 0

set -euo pipefail
cd "$(dirname "$0")"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cases=0
# check <what> <got> <want>
check() {
  cases=$((cases + 1))
  [ "$2" = "$3" ] || { echo "build-caps: $1: got '$2', want '$3'" >&2; exit 1; }
}

# The job count reaches the tool: a make and a cmake that say what they were
# given, first on the PATH.
mkdir "${work}/bin"
for tool in make cmake; do
  printf '#!/bin/sh\necho "%s $*"\n' "${tool}" > "${work}/bin/${tool}"
  chmod 0755 "${work}/bin/${tool}"
done
# said <BUILD_JOBS or empty> <function> [arguments...]: what the tool was given.
said() {
  local jobs="$1"
  shift
  if [ -n "${jobs}" ]; then
    BUILD_JOBS="${jobs}" PATH="${work}/bin:${PATH}" bash -c '. ./build-caps.sh && "$@"' - "$@"
  else
    env -u BUILD_JOBS PATH="${work}/bin:${PATH}" bash -c '. ./build-caps.sh && "$@"' - "$@"
  fi
}
check 'make, by default' "$(said '' capped_make)" 'make -j 4'
check 'make, BUILD_JOBS=2' "$(said 2 capped_make install)" 'make -j 2 install'
check 'cmake, by default' "$(said '' capped_cmake_build dir)" 'cmake --build dir -j 4'
check 'cmake, BUILD_JOBS=9' "$(said 9 capped_cmake_build dir)" 'cmake --build dir -j 9'

# A job count that is not one stops the build before it starts.
for bad in 0 -1 many 04 ''; do
  status=0
  BUILD_JOBS="${bad}" bash -c '. ./build-caps.sh && echo went on' > "${work}/out" 2> /dev/null || status=$?
  if [ "${bad}" = '' ]; then
    # Empty is unset: the default.
    check 'BUILD_JOBS empty' "$(cat "${work}/out")" 'went on'
  else
    check "BUILD_JOBS=${bad} is refused" "${status}:$(cat "${work}/out")" '2:'
  fi
done

# A step that outlasts BUILD_TIMEOUT is stopped, says so, and takes what it
# started with it.
status=0
BUILD_TIMEOUT=1s bash -c '. ./build-caps.sh && capped sh -c "sleep 60 & echo \$! > \"$1\"; wait"' - "${work}/pid" 2> "${work}/err" || status=$?
check 'a step past BUILD_TIMEOUT' "${status}" 124
grep -q 'stopped after 1s (BUILD_TIMEOUT)' "${work}/err" || { echo "build-caps: a stopped step does not say so" >&2; exit 1; }
sleep 1
if kill -0 "$(cat "${work}/pid")" 2> /dev/null; then
  kill "$(cat "${work}/pid")"
  echo "build-caps: a stopped step left what it started running" >&2
  exit 1
fi
cases=$((cases + 2))
# A step within it keeps its own status.
status=0
bash -c '. ./build-caps.sh && capped sh -c "exit 7"' || status=$?
check 'a failing step keeps its status' "${status}" 7

# build.sh runs make, cmake and configure through the functions, never bare.
if grep -nE '(^|[^_a-z])(make|cmake|\./configure)( |$)' build.sh | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE 'capped_make|capped_cmake_build|capped (make|cmake|\./configure) ' > "${work}/bare"; then
  cat "${work}/bare" >&2
  echo "build-caps: build.sh runs make, cmake or configure outside the caps" >&2
  exit 1
fi
cases=$((cases + 1))
echo "build-caps: ${cases} cases as expected"
