#!/usr/bin/env bash
# packages.sh (root, on a GitHub runner): what needs the network, before the namespace exists: jq, tcpdump, perf,
# Postgres 18 (installed, configured later by rig.sh), and the user `challenge` the entries build as.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
lookups() {
  for h in azure.archive.ubuntu.com archive.ubuntu.com github.com apt.postgresql.org download.swift.org \
           builds.dotnet.microsoft.com sqlite.org; do
    echo "dns $h: $(timeout 5 getent hosts $h > /dev/null && echo ok || echo FAILS)"
  done
}
# On 2026-11-11 one of Canonical's three nameservers stopped answering, and the runners' resolver (like Google's) then
# failed every *.ubuntu.com name while Cloudflare's answered: the runner asks Cloudflare when Ubuntu's mirror doesn't
# resolve.
if ! timeout 5 getent hosts azure.archive.ubuntu.com > /dev/null; then
  echo "azure.archive.ubuntu.com doesn't resolve: asking 1.1.1.1"
  mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNS=1.1.1.1 1.0.0.1\nDomains=~.\n' > /etc/systemd/resolved.conf.d/cloudflare.conf
  systemctl restart systemd-resolved
  sleep 2
fi
lookups
# An update that couldn't fetch an index counts as failed (Error-Mode=any); each apt step is tried four times.
retry() { for i in 1 2 3 4; do "$@" && return 0; echo "attempt $i of: $* failed; again in 30 s"; sleep 30; done; return 1; }
retry apt-get update -qq -o APT::Update::Error-Mode=any
retry apt-get install -y -qq postgresql-common jq tcpdump linux-tools-common "linux-tools-$(uname -r)" > /dev/null \
  || retry apt-get install -y -qq postgresql-common jq tcpdump linux-tools-generic > /dev/null
retry /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y > /dev/null
retry apt-get install -y -qq postgresql-18 > /dev/null
id challenge > /dev/null 2>&1 || useradd -m -s /bin/bash challenge
echo "packages done"
