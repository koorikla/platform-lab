#!/usr/bin/env bash
# Run every render assertion; each test is its own process so one failure doesn't hide the others.
set -euo pipefail
cd "$(dirname "$0")"
rc=0
for t in test_*.sh; do if bash "$t"; then echo "ok   $t"; else echo "FAIL $t"; rc=1; fi; done
exit $rc
