# Runbook: ServiceDown (WalletServiceDown / AuthServiceDown / WithdrawalServiceDown / ConversionServiceDown)

**Severity:** Critical
**SLO Impact:** Direct — end users cannot complete operations served by this service.

## Symptoms
- Alert fires when `up{job="wiseling/<service>"}` has been `0` for more than 1 minute.
- Requests to the service return connection refused or 5xx errors.

## Triage Steps

1. **Check pod status**
   ```bash
   kubectl get pods -n wiseling -l app=<service-name>
   ```
   Look for `CrashLoopBackOff`, `OOMKilled`, `Error`, or `Pending`.

2. **Check recent logs**
   ```bash
   kubectl logs -n wiseling -l app=<service-name> --tail=100 --previous
   ```

3. **Check events**
   ```bash
   kubectl describe pod -n wiseling -l app=<service-name> | tail -30
   ```

4. **Check node pressure**
   ```bash
   kubectl describe nodes | grep -A5 "Conditions:"
   ```

5. **Check database connectivity** (if logs show DB errors)
   ```bash
   kubectl get secret db-url-<service> -n wiseling -o jsonpath='{.data.DATABASE_URL}' | base64 -d
   ```

## Recovery

- If `CrashLoopBackOff`: fix the root cause (config, secret, DB), then `kubectl rollout restart deployment/<service>-deployment -n wiseling`
- If `OOMKilled`: increase memory limit in deployment YAML and redeploy
- If `Pending`: check node capacity with `kubectl describe nodes`

## Escalation
If the service does not recover within 10 minutes, escalate.
