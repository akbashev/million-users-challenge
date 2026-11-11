#!/usr/bin/env bash
# run.sh <entry> <label> <users> <think-scale> [ramp s] [hold s] (root): one million-rig run on a GitHub runner, kept in
# profile/out/<label>/. The entry as the board starts it (systemd, user challenge, PORT 80 + EXTRA_PORT 81, its env), inside
# namespace `bench` on CPU 0; Postgres on CPU 1 with a fresh `feed` from `feed_seed`; mload (-gzip) on CPUs 2-3. From 30 s into the hold: 60 s of CPU per request (the entry's
# cgroup, user and sys; CPUs 0+2 in all; Postgres), TCP segments per request; then 20 s of counters on CPUs 0+2,
# then 20 s of perf samples there. Also: system calls and io_uring
# operations of the entry's cgroup per request (with the counters), and 4 s of packets on lo (tcpdump), by kind.
set -uo pipefail
ENTRY=$1 LABEL=$2 USERS=$3 THINK=$4 RAMP=${5:-60} HOLD=${6:-180}
ROOT=$(cd "$(dirname "$0")/.." && pwd); B=/opt/bench; R=$ROOT/profile/out/$LABEL
PERF=$(ls /usr/lib/linux-tools/*/perf 2>/dev/null | head -1); [ -n "$PERF" ] || PERF=perf
rm -rf $R && mkdir -p $R
NS="ip netns exec bench"
sysctl -q -w fs.nr_open=8388608
systemctl stop chal 2>/dev/null; systemctl reset-failed chal 2>/dev/null
sudo -u postgres psql -qX -c "DROP DATABASE IF EXISTS feed WITH (FORCE)" -c "CREATE DATABASE feed OWNER feed TEMPLATE feed_seed"
systemctl restart postgresql@18-main
systemd-run -q --unit=chal --uid=challenge --gid=challenge -p NetworkNamespacePath=/run/netns/bench -p AllowedCPUs=0 \
  -p LimitNOFILE=8388608 -p AmbientCapabilities=CAP_NET_BIND_SERVICE -p WorkingDirectory=/home/challenge/sub/$ENTRY \
  --setenv=DATABASE_URL=postgres://feed:feed@127.0.0.1:5432/feed --setenv=JWT_SECRET=million-users-challenge \
  --setenv=HOST=0.0.0.0 --setenv=PORT=80 --setenv=EXTRA_PORT=81 /bin/bash start.sh
for _ in $(seq 120); do $NS curl -sf http://127.0.0.1:80/health >/dev/null && $NS curl -sf http://127.0.0.1:81/health >/dev/null && break; sleep 0.5; done
echo "$ENTRY: health $($NS curl -s -o /dev/null -w %{http_code} http://127.0.0.1:80/health)/$($NS curl -s -o /dev/null -w %{http_code} http://127.0.0.1:81/health)" | tee $R/start.txt
$NS taskset -c 2,3 $B/mload -target 127.0.0.1,127.0.0.2,127.0.0.3,127.0.0.4 -ports 80,81 -users $USERS -gzip \
  -think-scale $THINK -ramp ${RAMP}s -hold ${HOLD}s -tokens $B/tokens.json > $R/load.log 2>&1 &
LOAD=$!
CG=/sys/fs/cgroup/system.slice/chal.service
PG=$(dirname $(grep -l . /sys/fs/cgroup/system.slice/system-postgresql.slice/postgresql@18-main.service/cpu.stat 2>/dev/null || echo /nonexistent/cpu.stat))
cg() { awk '/^usage_usec|^user_usec|^system_usec/ {printf "%s ", $2}' $1/cpu.stat; }
cpus() { awk '/^cpu0 / {s += $2 + $3 + $4 + $7 + $8} END {print s}' /proc/stat; }
segs() { $NS awk '/^Tcp:/ { if (!h) { for (i = 1; i <= NF; i++) c[$i] = i; h = 1 } else print $c["OutSegs"], $c["RetransSegs"] }' /proc/net/snmp; }
sleep $((RAMP + 30))
read a0 u0 s0 < <(cg $CG); read p0 x y < <(cg $PG); c0=$(cpus); read o0 r0 < <(segs); t0=$(date +%s.%N); w0=$(grep -c '^t=' $R/load.log)
sleep 60
read a1 u1 s1 < <(cg $CG); read p1 x y < <(cg $PG); c1=$(cpus); read o1 r1 < <(segs); t1=$(date +%s.%N); w1=$(grep -c '^t=' $R/load.log)
rate=$(grep '^t=' $R/load.log | sed -n "$((w0 + 1)),${w1}p" | grep -o 'req/s=[0-9]*' | cut -d= -f2 | awk '{s+=$1;n++} END {print n ? s/n : 0}')
$PERF stat -x, -C 0 -e cycles,instructions,cache-misses,L1-dcache-load-misses,branch-misses -- sleep 20 2> $R/counters.csv &
HW=$!
EV=raw_syscalls:sys_enter,syscalls:sys_enter_io_uring_enter,syscalls:sys_enter_epoll_wait,syscalls:sys_enter_epoll_pwait,syscalls:sys_enter_read,syscalls:sys_enter_write,syscalls:sys_enter_writev,syscalls:sys_enter_sendmsg,syscalls:sys_enter_sendto,syscalls:sys_enter_recvfrom,syscalls:sys_enter_recvmsg,io_uring:io_uring_submit_req,io_uring:io_uring_complete,io_uring:io_uring_task_add
$PERF stat -x, -a --for-each-cgroup system.slice/chal.service -e $EV -- sleep 20 2> $R/calls.csv
wait $HW
$PERF record -q -C 0 -F 999 -e cpu-clock -g -o $R/perf.data -- sleep 20 2>/dev/null
peak=$(( $(cat $CG/memory.peak) / 1048576 ))
timeout 4 $NS tcpdump -i lo -nn -s 96 -B 262144 -w /dev/shm/$LABEL.pcap 'tcp port 80 or tcp port 81 or tcp port 5432' 2> $R/tcpdump.txt
tcpdump -r /dev/shm/$LABEL.pcap -nn 'tcp port 80 or tcp port 81' 2>/dev/null | awk '
  { split($3, s, "."); split($5, d, "."); dst = $5; sub(/:$/, "", dst); sp = s[5]; dp = d[5]; sub(/:$/, "", dp)
    f = $0; sub(/.*Flags \[/, "", f); sub(/\].*/, "", f); n = $0; sub(/.*length /, "", n); n += 0
    srv = (sp == "80" || sp == "81"); key = srv ? dst : $3
    if (srv) { if (n > 0) { sd++; if (last[key] == "s") split2++; if (last[key] == "a") ackfirst++; last[key] = "s" }
               else if (f ~ /F/) sf++; else if (f ~ /S/) ss++; else if (f ~ /R/) sr++; else { sa++; last[key] = "a" } }
    else { if (n > 0) { cd++; last[key] = "c" } else if (f ~ /F/) cf++; else if (f ~ /S|R/) cs++; else ca++ } }
  END { r = cd > 0 ? cd : 1
    printf "  packets per request (%d requests captured): server data %.3f, pure ACK %.3f (%.3f right before its response), FIN %.3f, RST %.3f;", cd, sd / r, sa / r, ackfirst / r, sf / r, sr / r
    printf " client data %.3f, pure ACK %.3f, FIN %.3f; responses in more than one segment %.3f\n", cd / r, ca / r, cf / r, split2 / r }' > $R/packets.txt
tcpdump -r /dev/shm/$LABEL.pcap -nn 'tcp port 5432' 2>/dev/null | awk -v r=$(cat $R/packets.txt | grep -o '([0-9]* requests' | tr -dc 0-9) '
  { n = $0; sub(/.*length /, "", n); n += 0; if ($3 ~ /\.5432$/) { if (n > 0) pd++; else pa++ } else { if (n > 0) sd++; else sa++ } }
  END { printf "  Postgres packets per request: server to Postgres data %.3f, pure ACK %.3f; Postgres to server data %.3f, pure ACK %.3f\n", sd / r, sa / r, pd / r, pa / r }' >> $R/packets.txt
mv /dev/shm/$LABEL.pcap $R/capture.pcap
wait $LOAD
journalctl -u chal --no-pager -o cat | tail -40 > $R/server.log
systemctl stop chal
$PERF report -i $R/perf.data --stdio --no-children --sort dso,sym -g none --percent-limit 0 2>/dev/null | grep -E '^ +[0-9]' \
  | { [ -x /opt/swift/usr/bin/swift-demangle ] && /opt/swift/usr/bin/swift-demangle --simplified || cat; } > $R/symbols.txt
{
  awk -v u=$((u1 - u0)) -v s=$((s1 - s0)) -v p=$((p1 - p0)) -v c=$((c1 - c0)) -v o=$((o1 - o0)) -v rt=$((r1 - r0)) -v r=$rate \
      -v t0=$t0 -v t1=$t1 -v l=$LABEL -v pk=$peak 'BEGIN {
    d = t1 - t0; req = r * d
    printf "%s: %.0f req/s; server %.1f us/req (user %.1f + sys %.1f); CPU 0 in all %.1f us/req (%.0f%% busy)\n", l, r,
      (u + s) / req, u / req, s / req, 1e4 * c / req, c / d
    printf "  Postgres %.1f us/req; TCP segments per request %.2f, retransmitted %d; server memory peak %d MB\n", p / req, o / req, rt, pk }'
  awk -F, -v r="$rate" '$3 != "" && $1 ~ /^[0-9]+$/ { printf "  %-22s %8.0f per request (CPU 0)\n", $3, $1 / (r * 20) }' $R/counters.csv
  cat $R/packets.txt; echo "  ($(grep -o '[0-9]* packets dropped by kernel' $R/tcpdump.txt))"
  awk -F, -v r="$rate" '$1 ~ /^[0-9]+$/ && $1 > 0 { e = $3; sub(/^(raw_)?syscalls:sys_enter_?/, "", e); sub(/^io_uring:io_uring_/, "uring ", e); if (e == "") e = "all syscalls"; printf "%s %.2f, ", e, $1 / (r * 20) } END { print "" }' $R/calls.csv | sed 's/^/  per request: /; s/, $//'
  echo "  worst 5 s: $(grep '^t=' $R/load.log | sed 's/.*p99=\([0-9.]*\)ms.*/\1 &/' | sort -rn | head -1 | cut -d' ' -f2- | cut -c1-100)"
  grep '^RESULT' $R/load.log | cut -c1-170 | sed 's/^/  /'
} | tee $R/summary.txt
