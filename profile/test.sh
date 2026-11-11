#!/usr/bin/env bash
# test.sh <entry> (root): the 42-check suite (test/run.sh) on an entry, inside the namespace where Postgres is.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
rm -rf /tmp/trepo && cp -r "$ROOT" /tmp/trepo && chmod -R a+rX /tmp/trepo
cd /tmp/trepo && ip netns exec bench sudo -u challenge -H env -u XDG_RUNTIME_DIR PGHOST=127.0.0.1 PGUSER=feed PGPASSWORD=feed \
  bash test/run.sh /home/challenge/sub/$1 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tee /tmp/test-$1.log | grep -E "passed=|FAIL" | tail -5
grep -q "passed=42 failed=0" /tmp/test-$1.log
