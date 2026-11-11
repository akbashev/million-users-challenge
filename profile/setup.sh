#!/usr/bin/env bash
# setup.sh (root, on a GitHub runner): the million rig on one machine. A network namespace `bench` (its own loopback,
# full port range, no firewall rules, so no connection tracking); Postgres 18 inside it on CPU 1, the box's config
# scaled to the runner, seeded by seed/make-seed.sh; user `challenge` with the entries installed and built; mload.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ip netns add bench
ip netns exec bench ip link set lo up
ip netns exec bench sysctl -q -w net.ipv4.ip_local_port_range="1024 65535" net.core.somaxconn=65535 \
  net.ipv4.tcp_max_syn_backlog=65535 net.ipv4.tcp_tw_reuse=1
sysctl -q -w fs.nr_open=8388608
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postgresql-common jq tcpdump linux-tools-common "linux-tools-$(uname -r)" > /dev/null \
  || apt-get install -y -qq postgresql-common jq tcpdump linux-tools-generic > /dev/null
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y > /dev/null
apt-get install -y -qq postgresql-18 > /dev/null
CONF=/etc/postgresql/18/main
sed -e 's/^shared_buffers.*/shared_buffers = 2GB/' -e 's/^effective_cache_size.*/effective_cache_size = 6GB/' \
    -e 's/^maintenance_work_mem.*/maintenance_work_mem = 512MB/' -e 's/^max_wal_size.*/max_wal_size = 4GB/' \
    -e 's/^min_wal_size.*/min_wal_size = 1GB/' -e 's/^max_worker_processes.*/max_worker_processes = 2/' \
    -e 's/^max_parallel_workers =.*/max_parallel_workers = 2/' \
    "$ROOT/box/postgresql.conf" > $CONF/conf.d/challenge.conf
echo "host feed,feed_seed feed 127.0.0.1/32 scram-sha-256" >> $CONF/pg_hba.conf
mkdir -p /etc/systemd/system/postgresql@18-main.service.d
printf '[Service]\nNetworkNamespacePath=/run/netns/bench\nAllowedCPUs=1\n' > /etc/systemd/system/postgresql@18-main.service.d/bench.conf
systemctl daemon-reload
systemctl restart postgresql@18-main
sudo -u postgres psql -qX -c "CREATE ROLE feed LOGIN CREATEDB PASSWORD 'feed'"
rm -rf /tmp/seed-build && cp -r "$ROOT/seed" /tmp/seed-build && cp "$ROOT/schema.sql" /tmp/ && chown -R postgres: /tmp/seed-build /tmp/schema.sql
sudo -u postgres PGUSER=postgres bash /tmp/seed-build/make-seed.sh | tail -1
# The seed's tables belong to postgres; the role the servers log in as needs them (DATABASE_URL's user is feed).
sudo -u postgres psql -qX -d feed_seed -c "ALTER TABLE users OWNER TO feed" -c "ALTER TABLE posts OWNER TO feed" \
  -c "ALTER TABLE likes OWNER TO feed"
sudo -u postgres psql -qX -c "ALTER DATABASE feed_seed OWNER TO feed" -c "ALTER DATABASE feed_seed WITH ALLOW_CONNECTIONS false"
mkdir -p /opt/bench && cp /tmp/seed-build/tokens.json /opt/bench/tokens.json && chmod a+r /opt/bench/tokens.json
useradd -m -s /bin/bash challenge
echo done
