# Incident: Immich Server CrashLoopBackOff — Poisoned Face Detection Queue

**Date:** 2026-05-18
**Duration:** ~3h 20m
**Severity:** major
**Service:** immich-server

## Summary

The immich-server pod entered CrashLoopBackOff due to a segmentation fault (exit code 139) triggered during face detection processing. On every restart, the Microservices worker immediately picked up the same queued jobs from Valkey, causing the process to crash within ~24 seconds of startup. The machine-learning pod was also unstable during this period, likely the upstream cause.

## Timeline

- `~18:15 UTC` — immich-server pod begins crash-looping (3h19m before investigation)
- `~18:15 UTC` — Machine-learning pod starts failing liveness probes
- `21:34 UTC` — Investigation started
- `21:36 UTC` — Root cause identified: exit code 139 (SIGSEGV) during face detection
- `21:37 UTC` — Valkey job queue flushed, server pod deleted
- `21:38 UTC` — Server pod running healthy, ML pod stabilized

## Root Cause

The immich-server container runs both the API worker (PID 25) and a Microservices worker (PID 7) in the same process. On startup, the Microservices worker immediately dequeues pending face detection jobs from Valkey and sends them to the machine-learning service for inference.

The machine-learning pod was unstable (failing liveness probes, restarting) during this period. It likely returned malformed or corrupt data for certain face detection requests. The server's native WASI-based image processing module segfaulted when handling these responses.

Because Valkey persists the job queue, every restart caused the server to immediately re-process the same poisoned jobs, creating an infinite crash loop.

## Resolution

1. Flushed the Valkey job queue: `kubectl exec -n immich immich-valkey-644cf9bffc-gwkf8 -- redis-cli FLUSHDB`
2. Deleted the crashing server pod to force a clean restart
3. Server came up healthy, ML pod also stabilized on its own

## Runbook

If immich-server enters CrashLoopBackOff with exit code 139:

1. Check logs for the last activity before crash:
   ```
   kubectl logs -n immich <server-pod> --previous --tail=30
   ```
2. If logs show face detection or ML-related processing, flush the job queue:
   ```
   kubectl exec -n immich <valkey-pod> -- redis-cli FLUSHDB
   ```
3. Delete the crashing pod:
   ```
   kubectl delete pod -n immich <server-pod>
   ```
4. Verify recovery:
   ```
   kubectl get pods -n immich
   ```
5. If crash recurs, check the ML pod health — it may need a restart too:
   ```
   kubectl rollout restart deployment/immich-machine-learning -n immich
   ```

## Prevention

- Added startup probe with `initialDelaySeconds: 10`, `periodSeconds: 5`, `failureThreshold: 60` — gives 5 minutes for startup while detecting crashes faster than the previous 10s interval
- Removed unused `IMMICH_HOST` env var (NestJS defaults to `0.0.0.0` when no host is specified)
- Tuned liveness/readiness probes for faster failure detection
