#!/usr/bin/env bash
# entries.sh <entry>... (root): each entry's install.sh as root and build.sh as `challenge`, in /home/challenge/sub.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p /home/challenge/sub
for e in "$@"; do
  rm -rf /home/challenge/sub/$e && cp -r "$ROOT/submissions/$e" /home/challenge/sub/$e && chown -R challenge: /home/challenge/sub/$e
  for i in 1 2 3; do (cd /home/challenge/sub/$e && bash install.sh > /tmp/install-$e.log 2>&1) && break; echo "$e: install attempt $i failed"; done
  (cd /home/challenge/sub/$e && sudo -u challenge -H bash build.sh > /tmp/build-$e.log 2>&1) || { echo "$e: build failed"; tail -30 /tmp/build-$e.log; exit 1; }
  echo "$e: built"
done
