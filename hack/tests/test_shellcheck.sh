#!/usr/bin/env bash
# Every shell script in the repo passes shellcheck (warnings and errors; sourced files followed from their callers).
source "$(dirname "$0")/lib.sh"
command -v shellcheck >/dev/null || { echo "skip: shellcheck not installed" >&2; exit 0; }
scripts=$(find bootstrap hack repos -name '*.sh' -not -path '*/charts/*' | sort)
[ -n "$scripts" ] || fail "no scripts found"
# shellcheck disable=SC2086  # one path per word
shellcheck -x -P SCRIPTDIR -S warning $scripts || fail "shellcheck"
