#!/usr/bin/env bash
# Host-side smoke test for the whole lab. Run after `vagrant up`, or `make verify`.
# Every check prints one greppable ok/FAIL line; any FAIL makes the script exit 1.
#
# Deliberately not `set -e`: one broken piece must not hide the state of the rest.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# Mirrors salt/pillar/common.sls. Repeated as literals so this stays a standalone
# script instead of teaching the host to parse the pillar tree.
CONTROLLER_IP=192.168.56.10                 # net:controller_ip
COMPUTE_IP=192.168.56.11                    # net:compute_ip
EXPORTER_PORT=9100                          # node_exporter:port
GATEWAY_PORT=30080                          # gateway:node_port
GRAFANA_HOST=grafana.local                  # grafana:host
KUBECONFIG_PATH=/etc/rancher/k3s/k3s.yaml   # k3s:kubeconfig
NAMESPACE=monitoring                        # monitoring:namespace
# The operator names the Prometheus service <release>-<chart>-prometheus, from
# monitoring:release (kps) and monitoring:kps_chart (kube-prometheus-stack).
PROM_SVC=kps-kube-prometheus-stack-prometheus

fail=0
report() {
	if [ "$1" -eq 0 ]; then
		printf 'ok    %s\n' "$2"
	else
		printf 'FAIL  %s\n' "$2"
		fail=1
	fi
}

status=$(vagrant status --machine-readable 2>/dev/null)
for expected in builder,state,poweroff controller,state,running compute,state,running; do
	printf '%s' "$status" | grep -q ",${expected}"
	report $? "vagrant: ${expected%%,*} is ${expected##*,}"
done

vagrant ssh controller -c 'sinfo -h -o %T' 2>/dev/null | grep -Eq 'idle|alloc|mix'
report $? "slurm: partition has an idle/alloc/mix node"

for ip in "$CONTROLLER_IP" "$COMPUTE_IP"; do
	curl -fsS --max-time 5 "http://${ip}:${EXPORTER_PORT}/metrics" >/dev/null 2>&1
	report $? "node exporter answers on ${ip}:${EXPORTER_PORT}"
done

# Roundtrip through the real NodePort, not a port-forward: this is the same path
# the Phase 5 job takes. The probe series expires on its own after the gateway TTL.
probe="verify_probe_$$"
gateway="http://${COMPUTE_IP}:${GATEWAY_PORT}"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X PUT \
	"${gateway}/update-metric" -H 'Content-Type: application/json' \
	-d "{\"name\":\"${probe}\",\"value\":1,\"labels\":{\"source\":\"verify\"}}")
put_ok=0
[ "$code" = "204" ] || put_ok=1
report "$put_ok" "gateway: PUT /update-metric returned ${code:-no response} (want 204)"

curl -fsS --max-time 5 "${gateway}/metrics" 2>/dev/null | grep -q "^${probe}{"
report $? "gateway: /metrics exposes ${probe}"

# Prometheus has no NodePort, so this runs from inside compute against the ClusterIP.
prom_ip=$(vagrant ssh compute -c \
	"KUBECONFIG=${KUBECONFIG_PATH} kubectl -n ${NAMESPACE} get svc ${PROM_SVC} -o jsonpath='{.spec.clusterIP}'" \
	2>/dev/null | tr -d '\r')
health=$(vagrant ssh compute -c "curl -s --max-time 10 http://${prom_ip}:9090/api/v1/targets" \
	2>/dev/null | grep -o '"health":"[a-z]*"')
total=$(printf '%s\n' "$health" | grep -c '"health"')
down=$(printf '%s\n' "$health" | grep -vc '"health":"up"')
targets_ok=0
{ [ "$total" -gt 0 ] && [ "$down" -eq 0 ]; } || targets_ok=1
report "$targets_ok" "prometheus: ${total} targets, ${down} not up"

printf '\n'
printf 'grafana: https://%s (admin/admin, Traefik self-signed certificate)\n' "$GRAFANA_HOST"
printf 'needs this line in /etc/hosts on the host: %s %s\n' "$COMPUTE_IP" "$GRAFANA_HOST"
exit "$fail"
