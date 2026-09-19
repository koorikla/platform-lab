#!/usr/bin/env bash
# Every chart's helm-unittest suites (unittest.sh), then every repo-level test (test_*.sh: config x chart integration,
# cross-chart contracts, scripts); each test is its own process so one failure doesn't hide the others.
set -euo pipefail
cd "$(dirname "$0")"
rc=0
bash unittest.sh || rc=1
for t in test_*.sh; do if bash "$t"; then echo "ok   $t"; else echo "FAIL $t"; rc=1; fi; done
exit $rc
