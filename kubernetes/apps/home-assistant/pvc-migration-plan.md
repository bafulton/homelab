# Home Assistant PVC Migration Plan

Migrate from StatefulSet-managed PVC to longhorn-storage chart-managed PVC with backup labels.

## Current State
- **PVC**: `home-assistant-home-assistant-0` (10Gi, ~500MB used)
- **Controller**: StatefulSet
- **Data**: `/config` with `.storage/`, `custom_components/`, `www/`, etc.

## Target State
- **PVC**: `home-assistant-config` (10Gi, with backup label)
- **Controller**: Deployment with `existingClaim`
- **Backups**: Daily Longhorn snapshots via RecurringJob

---

## Migration Steps

### Phase 1: Backup (safety net)
1. Create a Longhorn snapshot of the existing PVC via UI or CLI
   ```bash
   # Or via Longhorn UI: Volumes → pvc-db0ffd64-... → Take Snapshot
   ```
2. Verify snapshot exists before proceeding

### Phase 2: Deploy new infrastructure (non-destructive)
3. Commit Home Assistant chart changes:
   - Update `Chart.yaml` to add `longhorn-storage` dependency
   - Update `values.yaml` with `longhorn-storage` config (PVC + job)
   - **Keep StatefulSet and old persistence config for now**
4. ArgoCD syncs - creates:
   - New PVC `home-assistant-config` (empty, with backup label)
   - RecurringJob `home-assistant-daily`
5. **Home Assistant keeps running on old PVC** - no disruption yet

### Phase 3: Data migration
6. Scale down Home Assistant to 0 replicas:
   ```bash
   kubectl scale statefulset -n home-assistant home-assistant --replicas=0
   ```
7. Run a temporary pod that mounts both PVCs:
   ```bash
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: Pod
   metadata:
     name: pvc-migrator
     namespace: home-assistant
   spec:
     containers:
       - name: migrator
         image: busybox
         command: ["sleep", "3600"]
         volumeMounts:
           - name: old-pvc
             mountPath: /old
           - name: new-pvc
             mountPath: /new
     volumes:
       - name: old-pvc
         persistentVolumeClaim:
           claimName: home-assistant-home-assistant-0
       - name: new-pvc
         persistentVolumeClaim:
           claimName: home-assistant-config
     restartPolicy: Never
   EOF
   ```
8. Copy all data:
   ```bash
   kubectl exec -n home-assistant pvc-migrator -- sh -c 'cp -a /old/. /new/'
   ```
9. Verify file counts/sizes match:
   ```bash
   kubectl exec -n home-assistant pvc-migrator -- sh -c 'du -sh /old /new'
   kubectl exec -n home-assistant pvc-migrator -- sh -c 'ls -la /old /new'
   ```
10. Delete migrator pod:
    ```bash
    kubectl delete pod -n home-assistant pvc-migrator
    ```

### Phase 4: Switchover
11. Update Home Assistant `values.yaml`:
    - Change `controller.type` from `StatefulSet` to `Deployment`
    - Change `persistence` to use `existingClaim: home-assistant-config`
12. Commit and push
13. ArgoCD syncs - Home Assistant starts on new PVC
14. Verify Home Assistant works:
    - UI loads
    - Integrations connected
    - History/logbook has data
    - Automations running

### Phase 5: Cleanup (after 1 week)
15. Delete old PVC:
    ```bash
    kubectl delete pvc -n home-assistant home-assistant-home-assistant-0
    ```

---

## Rollback Plan

If anything goes wrong after Phase 4:

1. Revert `values.yaml`:
   - Change back to `controller.type: StatefulSet`
   - Remove `existingClaim`, restore original persistence config
2. Commit and push
3. ArgoCD syncs - Home Assistant restarts on original PVC
4. Data is intact because we never modified the original PVC

---

## Commands Reference

```bash
# Check current PVCs
kubectl get pvc -n home-assistant

# Check Longhorn snapshots
kubectl get snapshots.longhorn.io -n longhorn | grep home-assistant

# Watch Home Assistant pod status
kubectl get pods -n home-assistant -w

# Check Home Assistant logs after migration
kubectl logs -n home-assistant -l app.kubernetes.io/name=home-assistant --tail=100
```
