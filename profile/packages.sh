#!/usr/bin/env bash
# packages.sh (root, on a GitHub runner): what needs the network, before the namespace exists: jq, tcpdump, perf,
# Postgres 18 (installed, configured later by rig.sh), and the user `challenge` the entries build as.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# The runners' DNS fails now and then ("Temporary failure resolving"): every apt step is tried for about five minutes,
# and an update that couldn't fetch an index counts as failed (Error-Mode=any).
retry() { for i in $(seq 10); do "$@" && return 0; echo "attempt $i of: $* failed; again in 30 s"; sleep 30; done; return 1; }
retry apt-get update -qq -o APT::Update::Error-Mode=any
retry apt-get install -y -qq postgresql-common jq tcpdump linux-tools-common "linux-tools-$(uname -r)" > /dev/null \
  || retry apt-get install -y -qq postgresql-common jq tcpdump linux-tools-generic > /dev/null
retry /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y > /dev/null
retry apt-get install -y -qq postgresql-18 > /dev/null
id challenge > /dev/null 2>&1 || useradd -m -s /bin/bash challenge
echo "packages done"
