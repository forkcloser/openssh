#!/usr/bin/env bash
#
# Write the notices of every source the package links, as the sources state
# them, one of each.
#   notices.sh <file to write> <name>=<directory>[=<depth>]... [<name>:<file>...]
#   notices.sh --test
# A depth of 1 takes the directory's own files and leaves its
# subdirectories: a tree's tests and contributed files are not linked.
# A <name>:<file> is a notice written out in this repository, for a source
# that names an author and leaves the terms to be found elsewhere.
#
# A library's licence file is its project's summary, and a summary can be
# short of what the sources ask: LibreSSL's COPYING holds the OpenSSL and
# SSLeay texts and says the rest is ISC, where the ISC files each carry a
# holder's notice that asks to appear in every copy; libfido2's holds
# Yubico's alone, where it compiles two files of another holder. The
# archive carries the summaries and this file, which is taken from the
# sources: every run of comments that speaks of a copyright, in each .c, .h
# and .S of the directories named.
#
# The sources of a directory, whether this platform compiles them or not:
# one notice too many costs nothing, and the list needs no knowledge of the
# build. A notice whose terms are not one of the kinds below stops the
# build: someone reads it before it ships.

set -euo pipefail
export LC_ALL=C

if [ "${1:-}" = --test ]; then
  # What has to stop a build, and what must not: each case a source of its
  # own, the script run on it as the build runs it.
  self=$0
  cases=$(mktemp -d)
  trap 'rm -rf "${cases}"' EXIT
  isc='/*
 * Copyright (c) 2001 First Holder
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 */'
  mkdir "${cases}/plain" "${cases}/later" "${cases}/gpl" "${cases}/string" "${cases}/string-after" "${cases}/trailing" "${cases}/after-end"
  printf '%s\nint a;\n' "${isc}" > "${cases}/plain/a.c"
  printf '#ifndef A_H\n#define A_H\n%s\n#endif\n' "${isc}" > "${cases}/later/a.h"
  printf '/*\n * Copyright (c) 2020 Someone\n * under the terms of the GNU General Public License.\n */\nint a;\n' > "${cases}/gpl/a.c"
  printf 'static const char banner[] = "Copyright 2020 Someone";\n' > "${cases}/string/a.c"
  printf '%s\nstatic const char copyright[] = "Copyright (c) 1983 Second Holder";\n' "${isc}" > "${cases}/string-after/a.c"
  printf '%s\nint d; /* Copyright (c) 2021 Third Holder. */\n' "${isc}" > "${cases}/trailing/a.c"
  printf '/* %s */ /* Copyright (c) 2022 Fourth Holder */\nint a;\n' 'a comment' > "${cases}/after-end/a.c"
  failed=0
  for want in 'ok plain' 'ok later' 'stop gpl' 'stop string' 'stop string-after' 'stop trailing' 'stop after-end'; do
    name=${want#* }
    if "${self}" "${cases}/out" "case=${cases}/${name}" > /dev/null 2>&1; then got=ok; else got=stop; fi
    [ "${got}" = "${want% *}" ] || { echo "notices.sh: the case '${name}' gives ${got}, want ${want% *}" >&2; failed=1; }
    if [ "${got}" = stop ] && [ -e "${cases}/out" ]; then echo "notices.sh: the case '${name}' stopped and left a file" >&2; failed=1; fi
    rm -f "${cases}/out"
  done
  if ! "${self}" "${cases}/out" "case=${cases}/later" > /dev/null 2>&1 || ! grep -q 'First Holder' "${cases}/out"; then
    echo "notices.sh: a notice after an include guard is not in the file" >&2
    failed=1
  fi
  [ "${failed}" -eq 0 ] || exit 1
  echo "notices.sh: 7 cases as expected"
  exit 0
fi

out=${1:?the file to write}
shift
[ $# -gt 0 ] || { echo "notices.sh: no <name>=<directory> given" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# The notices of a source: each run of comments that speaks of a copyright,
# wherever it is in the file, markers stripped, one record a run: the path,
# \035, the lines joined by \034. Not a tab between the two: a notice has
# tabs of its own. Comments with only blank lines between them are one run,
# since a notice is often two comments. A line that says "copyright" and is
# not read into a run (code, a string, a comment that follows code on its
# line, what follows a comment's end) is a notice this did not reach: the
# source's record says so, and stops the build below, whatever else the
# source yielded.
# shellcheck disable=SC2016 # awk's variables, not the shell's
notices_of='
function emit(  t, flat) {
  t = text
  text = ""
  gsub(/^\034+/, "", t)
  gsub(/\034+$/, "", t)
  if (t == "") return
  flat = tolower(t)
  gsub(/\034/, " ", flat)
  if (flat !~ /copyright|public domain|permission to use|permission is hereby granted|redistribution and use/) return
  printf "%s\035%s\n", FILENAME, t
}
function add(line) {
  sub(/[ \t]+$/, "", line)
  # A revision line names the file: with it, no two notices are the same.
  if (line ~ /\$(OpenBSD|NetBSD|FreeBSD|Id)[:$]/) return
  # So does a line that is the path of the file itself: the SSLeay files open with one.
  if (line ~ /^[A-Za-z0-9_\/.-]+\.[chS]$/) return
  text = text line "\034"
}
{
  line = $0
  sub(/\r$/, "", line)
  if (!incomment) {
    if (line ~ /^[ \t]*$/) { if (text != "") text = text "\034"; next }
    if (line ~ /^[ \t]*\/\*/) { incomment = 1; sub(/^[ \t]*\/\*+/, "", line) }
    else if (line ~ /^[ \t]*\/\//) { sub(/^[ \t]*\/\/+ ?/, "", line); add(line); next }
    else if (FILENAME ~ /\.S$/ && (line ~ /^[ \t]*[;#][ \t]/ || line ~ /^[ \t]*[;#]$/)) { sub(/^[ \t]*[;#]+ ?/, "", line); add(line); next }
    else { if (tolower(line) ~ /copyright/) unreached = 1; emit(); next }
  }
  if (line ~ /\*\//) {
    incomment = 0
    rest = substr(line, index(line, "*/") + 2)
    if (tolower(rest) ~ /copyright/) unreached = 1
    sub(/[ \t]*\*+\/.*$/, "", line)
  }
  sub(/^[ \t]*\*+ ?/, "", line)
  add(line)
}
END {
  emit()
  if (unreached) printf "%s\035\036\n", FILENAME
}
'

failed=0
sep=$(printf '\035')
: > "${out}"
{
  echo "The notices of the sources this package links, as each source states"
  echo "them, one of each. The licence files beside this one are each project's"
  echo "own statement; this one is what the sources ask to be reproduced."
} >> "${out}"

stated_elsewhere=0
for pair in "$@"; do
  case "${pair}" in
    *=*) ;;
    *:*)
      [ -s "${pair#*:}" ] || { echo "notices.sh: ${pair%%:*}: no notice at ${pair#*:}" >&2; exit 1; }
      {
        echo
        echo "================================================================"
        echo "${pair%%:*}"
        echo "================================================================"
        echo
        cat "${pair#*:}"
      } >> "${work}/written"
      continue
      ;;
    *) echo "notices.sh: neither <name>=<directory> nor <name>:<file>: ${pair}" >&2; exit 1 ;;
  esac
  name=${pair%%=*}
  dir=${pair#*=}
  depth=()
  case "${dir}" in
    *=*)
      depth=(-maxdepth "${dir##*=}")
      dir=${dir%=*}
      ;;
    *) ;;
  esac
  [ -d "${dir}" ] || { echo "notices.sh: ${name}: no directory ${dir}" >&2; exit 1; }
  : > "${work}/heads"
  find "${dir}" ${depth[@]+"${depth[@]}"} -type f \( -name '*.c' -o -name '*.h' -o -name '*.S' \) | sort > "${work}/files"
  [ -s "${work}/files" ] || { echo "notices.sh: ${name}: no source under ${dir}" >&2; exit 1; }
  while read -r file; do
    awk "${notices_of}" "${file}" >> "${work}/heads"
  done < "${work}/files"

  # One line a notice: its kind, its path, its text.
  awk -F '\035' '
    {
      path = $1; text = $2; low = tolower(text); flat = low
      gsub(/\034/, " ", flat); gsub(/[ \t]+/, " ", flat)
      kind = "unknown"
      if (text == "\036") kind = "unreached"
      else if (flat ~ /permission to use, copy, modify,? and(\/or)? distribute/) kind = "isc"
      else if (flat ~ /redistribution and use in source and binary forms/) kind = "bsd"
      else if (flat ~ /permission is hereby granted, free of charge/) kind = "mit"
      else if (flat ~ /public domain/) kind = "public-domain"
      else if (flat ~ /spdx-license-identifier: (bsd-2-clause|bsd-3-clause|isc|mit)/) kind = "by-reference"
      else if (flat ~ /licensed under the mit license|under the terms of the mit license/) kind = "by-reference"
      else if (flat ~ /governed by a bsd-style license that can be found in the license file/) kind = "by-reference"
      else if (flat ~ /licensed under the openssl license|governed by openssl license|granted according to the openssl license/) kind = "by-reference"
      else if (flat ~ /as-is.*without any express or implied warranty.*permission is granted to anyone to use this software/) kind = "zlib"
      else if (flat ~ /can be used freely for any purpose\. +any derived versions of this software must be clearly marked as such/) kind = "ylonen"
      else if (flat ~ /may be used for any purpose as long as this notice remains intact/) kind = "notice-kept"
      else if (flat ~ /unlimited permission to copy and\/or distribute it, with or without modifications, as long as this notice is preserved/) kind = "notice-kept"
      else if (flat ~ /modification and redistribution in source and binary forms is permitted provided that due credit is given/) kind = "notice-kept"
      else if (flat ~ /copyright of this function: \(c\) 2008-2009 bjoern hoehrmann/) kind = "stated-elsewhere"
      printf "%s\035%s\035%s\n", kind, path, text
    }' "${work}/heads" > "${work}/kinds"

  if grep -q '^unknown' "${work}/kinds"; then
    echo "notices.sh: ${name}: terms this script does not know, in:" >&2
    awk -F "${sep}" '$1 == "unknown" { print $2 }' "${work}/kinds" | sort -u | sed "s#^${dir}/#  #" >&2
    failed=1
  fi
  if grep -q '^stated-elsewhere' "${work}/kinds"; then stated_elsewhere=1; fi
  if grep -q '^unreached' "${work}/kinds"; then
    echo "notices.sh: ${name}: a copyright is stated where this script reads none, in:" >&2
    awk -F "${sep}" '$1 == "unreached" { print $2 }' "${work}/kinds" | sed "s#^${dir}/#  #" >&2
    failed=1
  fi

  {
    echo
    echo "================================================================"
    echo "${name}"
    echo "================================================================"
    awk -F "${sep}" '$1 != "unknown" && $1 != "unreached" { print $3 }' "${work}/kinds" | sort -u | while IFS= read -r notice; do
      echo
      printf '%s\n' "${notice}" | tr '\034' '\n'
      echo "----------------------------------------------------------------"
    done
  } >> "${out}"
  echo "notices: ${name}: $(grep -c . "${work}/files") sources, $(awk -F "${sep}" '$1 != "unknown" && $1 != "unreached" { print $3 }' "${work}/kinds" | sort -u | grep -c . || true) distinct notices"
done

# The one source known to name an author and no terms: its terms are a
# notice of this repository, and have to have been given.
if [ "${stated_elsewhere}" -eq 1 ] && ! grep -q 'Bjoern Hoehrmann' "${work}/written" 2> /dev/null; then
  echo "notices.sh: a source names Bjoern Hoehrmann and no terms, and no <name>:<file> gives them" >&2
  failed=1
fi
[ ! -s "${work}/written" ] || cat "${work}/written" >> "${out}"

[ "${failed}" -eq 0 ] || { rm -f "${out}"; exit 1; }
