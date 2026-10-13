#!/usr/bin/env bash
# summary: Sessions pile up behind one row lock and nothing alerts — write the alert (needs --observability)
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/08-saturation-alert/common.sh"

if ! prometheus_up; then
  die "this scenario needs Prometheus and Grafana — start the lab with: ./lab up --observability"
fi

stop_pileup
start_pileup
info "Application sessions are piling up on the primary (container $PILEUP_CONTAINER)."
echo "Checkout requests time out, yet no alert has fired. Use Grafana"
echo "(http://127.0.0.1:${DBRE_GRAFANA_PORT:-13000}, dashboard 'DBRE Lab — MySQL') or Prometheus"
echo "(http://127.0.0.1:${DBRE_PROMETHEUS_PORT:-19090}) to see what is saturated, then write an"
echo "alert rule in observability/prometheus/rules.d/saturation.yml that fires on it."
echo "Then: ./lab check 08-saturation-alert"
