# Runbook: PodCrashLooping

**Severity:** Critical
**SLO Impact:** Partial to Full — repeated crashes reduce or eliminate service capacity.

## Symptoms
- Alert fires when `rate(kube_pod_container_status_restarts_total[5m]) > 0` for more than 2 minutes.
- Pod status shows `CrashLoopBackOff` in `kubectl get pods`.

## Triage Steps

1. **Identify the crashing pod**
   ```bash
   kubectl get pods -n wiseling | grep CrashLoop
   ```

2. **Check exit code and crash reason**
   ```bash
   kubectl describe pod <pod-name> -n wiseling | grep -A5 "Last State"
   ```
   Common exit codes:
   - `exit 1` — application error (check logs)
   - `exit 137` — OOMKilled (increase memory limit)
   - `exit 139` — segfault (bug in application)

3. **Read the last crash logs**
   ```bash
   kubectl logs <pod-name> -n wiseling --previous --tail=200
   ```

4. **Check if a config or secret changed recently**
   ```bash
   kubectl get events -n wiseling --sort-by='.lastTimestamp' | tail -20
   ```

5. **Check resource limits**
   ```bash
   kubectl get pod <pod-name> -n wiseling -o jsonpath='{.spec.containers[0].resources}'
   ```

## Recovery

- If OOMKilled: increase memory limit in the deployment YAML and reapply
- If application error: fix the bug, build a new image, and update the deployment tag
- If bad config/secret: fix the ConfigMap or Secret and restart the pod
  ```bash
  kubectl rollout restart deployment/<service>-deployment -n wiseling
  ```
- Temporary mitigation (buys time for root cause fix):
  ```bash
  kubectl scale deployment/<service>-deployment -n wiseling --replicas=0
  # Fix the issue, then:
  kubectl scale deployment/<service>-deployment -n wiseling --replicas=2
  ```

## Escalation
If the pod does not stabilise within 15 minutes, escalate to the on-call engineer with the crash logs attached.
