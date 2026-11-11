#!/usr/bin/env bash
# packages.sh (root, on a GitHub runner): what needs the network, before the namespace exists: jq, tcpdump, perf,
# Postgres 18 (installed, configured later by rig.sh), and the user `challenge` the entries build as.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
for h in azure.archive.ubuntu.com archive.ubuntu.com security.ubuntu.com github.com apt.postgresql.org download.swift.org \
         builds.dotnet.microsoft.com sqlite.org; do
  echo "dns $h: $(getent hosts $h > /dev/null && echo ok || echo FAILS)"
done
# The runners' apt mirror list names only azure.archive.ubuntu.com, which didn't resolve on 2026-11-11 while other
# names did: the main archive instead when it doesn't (the entries' install.sh use the same list).
if ! getent hosts azure.archive.ubuntu.com > /dev/null && [ -f /etc/apt/apt-mirrors.txt ]; then
  echo "using archive.ubuntu.com"; echo "http://archive.ubuntu.com/ubuntu/" > /etc/apt/apt-mirrors.txt
fi
# An update that couldn't fetch an index counts as failed (Error-Mode=any); each apt step is tried four times.
retry() { for i in 1 2 3 4; do "$@" && return 0; echo "attempt $i of: $* failed; again in 30 s"; sleep 30; done; return 1; }
retry apt-get update -qq -o APT::Update::Error-Mode=any
retry apt-get install -y -qq postgresql-common jq tcpdump linux-tools-common "linux-tools-$(uname -r)" > /dev/null \
  || retry apt-get install -y -qq postgresql-common jq tcpdump linux-tools-generic > /dev/null
retry /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y > /dev/null
retry apt-get install -y -qq postgresql-18 > /dev/null
id challenge > /dev/null 2>&1 || useradd -m -s /bin/bash challenge
echo "packages done"
