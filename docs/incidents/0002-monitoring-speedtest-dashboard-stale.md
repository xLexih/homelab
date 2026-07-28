# Incident: Monitoring Speedtest Dashboard Stale After Prometheus Storage Exhaustion

> Archived legacy application incident. Referenced `apps/` files are no longer
> part of the active cluster project.

**Date:** 2026-07-01
**Duration:** ~35m
**Severity:** minor
**Service:** monitoring / grafana / prometheus / speedtest

## Summary

The Grafana speedtest dashboard showed old data, but pressing the on-demand speed test button did not appear to update the graphs. The speedtest controller and exporter were healthy and manual runs were accepted, but Grafana panel queries were returning HTTP 400 after the monitoring stack recovered from a Prometheus disk-full crash loop.

## Timeline

- `13:42 UTC` — Prometheus logs showed `no space left on device` while replaying `/prometheus/chunks_head`
- `13:45 UTC` — Prometheus PVC resized from `20Gi` to `50Gi` and Helm values updated
- `13:46 UTC` — Prometheus pod became ready again
- `13:49 UTC` — Grafana successfully proxied `POST /api/datasources/proxy/uid/speedtest-trigger/run` with HTTP 202
- `13:50 UTC` — Speedtest exporter completed fresh manual runs
- `13:58 UTC` — Investigation found speedtest dashboard panel queries returning HTTP 400
- `14:01 UTC` — Dashboard ConfigMap updated, `grafana_dashboard=1` restored, Grafana dashboards reloaded
- `14:02 UTC` — Grafana query API returned fresh speedtest data with HTTP 200

## Root Cause

There were two related problems.

First, Prometheus exhausted its `20Gi` Longhorn PVC and entered CrashLoopBackOff during TSDB WAL/head replay:

```text
panic: write /prometheus/chunks_head/000322: no space left on device
```

This stopped new monitoring data ingestion until the PVC was expanded.

Second, after Prometheus recovered, the speedtest dashboard still failed to render fresh data because the live dashboard had drifted into using the templated datasource variable `${DS_PROMETHEUS}`. Grafana stored that variable's current value as `Prometheus`, while the actual datasource UID is `prometheus`. Panel queries through Grafana returned HTTP 400 even though direct Prometheus queries and Grafana queries pinned to UID `prometheus` succeeded.

The dashboard button itself was not the primary failure. It successfully proxied `POST /run` to the speedtest controller. However, the old button behavior reloaded the page after a fixed 5 seconds, which could happen before the speedtest completed and made the failure look like the trigger did nothing.

## Resolution

1. Expanded Prometheus storage:
   ```sh
   kubectl patch pvc prometheus-grafana-kube-prometheus-st-prometheus-db-prometheus-grafana-kube-prometheus-st-prometheus-0 \
     -n monitoring \
     -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
   ```
2. Updated `apps/monitoring/values.yaml` so Prometheus requests `50Gi`.
3. Ran the Helm upgrade for the monitoring stack.
4. Updated `apps/monitoring/speedtest-dashboard.json` to pin all panels directly to datasource UID `prometheus`.
5. Removed the unused `DS_PROMETHEUS` dashboard variable.
6. Changed the button behavior to poll `/status` and refresh only after the speedtest completes.
7. Re-applied `speedtest-dashboard` ConfigMap and restored `grafana_dashboard=1`.

## Runbook

If the speedtest dashboard shows old or empty data:

1. Check monitoring pod health:
   ```sh
   kubectl get pods -n monitoring
   ```
2. If Prometheus is crash-looping, check previous logs:
   ```sh
   kubectl logs -n monitoring prometheus-grafana-kube-prometheus-st-prometheus-0 -c prometheus --previous
   ```
3. Check PVC capacity:
   ```sh
   kubectl get pvc -n monitoring
   ```
4. If logs show `no space left on device`, expand the Prometheus PVC and update `apps/monitoring/values.yaml`.
5. Verify the controller accepts manual runs:
   ```sh
   kubectl exec -n monitoring deploy/speedtest-controller -- python -c 'import urllib.request; req=urllib.request.Request("http://127.0.0.1:8080/run", method="POST"); print(urllib.request.urlopen(req, timeout=10).status)'
   ```
6. Verify controller state:
   ```sh
   kubectl exec -n monitoring deploy/speedtest-controller -- python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/status", timeout=10).read().decode())'
   ```
7. Verify Prometheus has fresh speedtest data:
   ```sh
   kubectl exec -n monitoring deploy/speedtest-controller -- python -c 'import urllib.parse, urllib.request; q=urllib.parse.quote("speedtest_download_bits_per_second / 1000000"); print(urllib.request.urlopen("http://grafana-kube-prometheus-st-prometheus.monitoring.svc:9090/api/v1/query?query="+q, timeout=10).read().decode())'
   ```
8. If Grafana still shows empty panels, check that the live dashboard uses datasource UID `prometheus`, not `${DS_PROMETHEUS}`.
9. Re-apply the dashboard ConfigMap and label:
   ```sh
   kubectl create configmap speedtest-dashboard \
     --namespace monitoring \
     --from-file=speedtest.json=apps/monitoring/speedtest-dashboard.json \
     --dry-run=client -o yaml | kubectl apply -f -
   kubectl label configmap speedtest-dashboard -n monitoring grafana_dashboard=1 --overwrite
   ```

## Prevention

- Prometheus storage was increased from `20Gi` to `50Gi`.
- The speedtest dashboard now pins datasource UID `prometheus` directly instead of relying on a mutable dashboard datasource variable.
- The button now waits for the controller to report completion before refreshing the dashboard.
- Keep `grafana_dashboard=1` on the speedtest dashboard ConfigMap; the Grafana sidecar ignores it without that label.
