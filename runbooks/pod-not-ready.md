# Runbook: PodNotReady

**Severity:** Critical
**SLO Impact:** Partial — reduced capacity, requests may fail if all replicas are affected.

## Symptoms
- Alert fires when a service pod has had `Ready=False` for more than 1 minute.
- The pod exists and is running but is failing its readiness probe.

## Triage Steps

1. **Identify the affected pod**
   ```bash
   kubectl get pods -n wiseling -o wide | grep -v Running
   ```

2. **Check readiness probe failure reason**
   ```bash
   kubectl describe pod <pod-name> -n wiseling | grep -A10 "Readiness"
   ```

3. **Check pod logs for application errors**
   ```bash
   kubectl logs <pod-name> -n wiseling --tail=100
   ```

4. **Check CPU/memory utilisation** (probe timeouts under heavy load)
   ```bash
   kubectl top pod <pod-name> -n wiseling
   ```

5. **Check if the database is reachable** (common cause for worker pods)
   ```bash
   kubectl exec -n wiseling <pod-name> -- env | grep DATABASE_URL
   ```

## Recovery

- If caused by CPU throttling: scale up the deployment or increase CPU limits
  ```bash
  kubectl scale deployment/<service>-deployment -n wiseling --replicas=3
  ```
- If caused by a bad deployment: roll back
  ```bash
  kubectl rollout undo deployment/<service>-deployment -n wiseling
  ```
- If transient (e.g., startup): wait one more probe cycle (10s) and re-evaluate

## Escalation
If the pod does not become ready within 5 minutes, treat as ServiceDown and escalate.
