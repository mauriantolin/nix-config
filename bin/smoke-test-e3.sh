#!/usr/bin/env bash
# Smoke test Fase E.3 — prometheus + grafana + exporters (node, blackbox, postgres)
# Convención: igual que smoke-test-e1.sh — check name + comando, exit code = #fails
# Las checks que hacen queries Prometheus van via `ssh ... bash -s` con heredoc para
# evitar quoting hell con zsh remoto y caracteres { } " en PromQL.
set -uo pipefail

HOST="${HOST:-mauri@home-server}"
FAIL=0

check() {
  local name="$1"
  shift
  printf '%-65s ' "$name"
  if "$@" >/dev/null 2>&1; then
    echo OK
  else
    echo FAIL
    FAIL=1
  fi
}

# Helper: corre un script bash via SSH leyendo de stdin (evita escape hell).
remote_bash() {
  ssh "$HOST" bash -s
}

echo "=== Smoke test Fase E.3 ==="

# === Prometheus ===

check "1 prometheus listening on 127.0.0.1:9090 only" ssh "$HOST" "
  sudo ss -tnlp | grep -q '127.0.0.1:9090' && \
  ! sudo ss -tnlp | grep -E ':9090' | grep -qv '127.0.0.1'"

check "2 prometheus /api/v1/targets reachable" bash -c '
  remote_bash() { ssh "'"$HOST"'" bash -s; }
  remote_bash <<"EOF"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:9090/api/v1/targets")
  [ "$CODE" = "200" ]
EOF
'

check "3 all baseline jobs healthy (prometheus/node/postgres up)" bash -c '
  ssh '"$HOST"' bash -s <<"EOF"
  for job in prometheus node postgres; do
    RESP=$(curl -sG --data-urlencode "query=up{job=\"$job\"}" http://127.0.0.1:9090/api/v1/query)
    echo "$RESP" | grep -q "\"value\":\[[0-9.]*,\"1\"\]" || exit 1
  done
EOF
'

check "4 node_load1 metric scraped (numeric value present)" bash -c '
  ssh '"$HOST"' bash -s <<"EOF"
  curl -sG --data-urlencode "query=node_load1" http://127.0.0.1:9090/api/v1/query | \
    grep -qE "\"value\":\[[0-9.]+,\"[0-9.]+\"\]"
EOF
'

check "5 blackbox probe vault.* succeeds (probe_success=1)" bash -c '
  ssh '"$HOST"' bash -s <<"EOF"
  RESP=$(curl -sG --data-urlencode "query=probe_success{instance=\"https://vault.mauricioantolin.com\"}" http://127.0.0.1:9090/api/v1/query)
  echo "$RESP" | grep -q "\"value\":\[[0-9.]*,\"1\"\]"
EOF
'

check "6 postgres-exporter scrape OK (pg_up=1)" bash -c '
  ssh '"$HOST"' bash -s <<"EOF"
  RESP=$(curl -sG --data-urlencode "query=pg_up" http://127.0.0.1:9090/api/v1/query)
  echo "$RESP" | grep -q "\"value\":\[[0-9.]*,\"1\"\]"
EOF
'

# === Exporters direct ===

check "7 node-exporter on 127.0.0.1:9100 returns metrics" ssh "$HOST" '
  curl -s http://127.0.0.1:9100/metrics | grep -q "^node_load1 "'

check "8 blackbox-exporter on 127.0.0.1:9115 reachable" bash -c '
  ssh '"$HOST"' bash -s <<"EOF"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:9115/probe?target=https://whoami.mauricioantolin.com&module=http_2xx")
  [ "$CODE" = "200" ]
EOF
'

check "9 postgres-exporter on 127.0.0.1:9187 returns metrics" ssh "$HOST" '
  curl -s http://127.0.0.1:9187/metrics | grep -q "^pg_up "'

# === Grafana ===

check "10 grafana /api/health returns 200" ssh "$HOST" '
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3030/api/health)
  [ "$CODE" = "200" ]'

check "11 grafana DB connection clean (no FATAL in journal)" ssh "$HOST" "
  ! sudo journalctl -u grafana --no-pager -n 200 | grep -qE 'FATAL|database is locked|password authentication failed'"

check "12 grafana datasource Prometheus provisionada" ssh "$HOST" '
  PASS=$(sudo cat /run/agenix/grafanaAdminPass)
  RESP=$(curl -s -u "admin:$PASS" http://127.0.0.1:3030/api/datasources)
  echo "$RESP" | grep -q "\"type\":\"prometheus\""'

check "13 grafana 2 dashboards provisionados (homelab-overview + zfs-pool)" ssh "$HOST" '
  PASS=$(sudo cat /run/agenix/grafanaAdminPass)
  curl -s -u "admin:$PASS" "http://127.0.0.1:3030/api/dashboards/uid/homelab-overview" | grep -q "\"uid\":\"homelab-overview\"" && \
  curl -s -u "admin:$PASS" "http://127.0.0.1:3030/api/dashboards/uid/zfs-pool" | grep -q "\"uid\":\"zfs-pool\""'

check "14 grafana via Tailscale Serve subpath responde" ssh "$HOST" '
  CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 https://home-server.tailee5654.ts.net/grafana/api/health)
  [ "$CODE" = "200" ]'

# === Datasets ===

check "15 datasets E.3 mounted (prometheus2 + grafana)" ssh "$HOST" "
  mountpoint -q /var/lib/prometheus2 && \
  mountpoint -q /var/lib/grafana"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ Fase E.3 verde"
  exit 0
else
  echo "✗ Al menos un check falló"
  exit 1
fi
