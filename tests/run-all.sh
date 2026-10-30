#!/usr/bin/env bash
# Run every test script in this directory: tests/run-all.sh
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
rc=0
for t in *.test.sh; do echo "== $t"; bash "$t" || rc=1; done
exit $rc
