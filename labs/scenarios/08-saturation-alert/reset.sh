#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/08-saturation-alert/common.sh"

stop_pileup
rm -f "$RULE_FILE"
if prometheus_up; then
  prom_reload >/dev/null || warn "Prometheus reload failed — see: ./lab logs prometheus"
fi
info "08-saturation-alert reset: pile-up stopped, rules.d/saturation.yml removed"
