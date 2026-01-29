# Reducing OSD CPU Overcommit

**Problem:** Node ocp-virt4-ceph7 shows 226% CPU overcommit with 6 OSDs, causing OSD crashes and VM pauses.

**Root Cause:** BlueStore watch timeouts during high CPU contention on ocp-virt4-ceph7.

**Goal:** Reduce CPU overcommit to 100-150% through configuration tuning.

---

## Table of Contents

1. [Quick Diagnosis](#quick-diagnosis)
2. [Immediate Configuration Changes](#immediate-configuration-changes)
3. [Resource Limit Solutions](#resource-limit-solutions)
4. [Long-Term Architecture Changes](#long-term-architecture-changes)
5. [Verification Commands](#verification-commands)

---

## Quick Diagnosis

### Check Current CPU Overcommit

```bash
# Check node resource allocation
oc describe node ocp-virt4-ceph7 | grep -A 20 "Allocated resources:"

# Check OSD pod CPU usage
oc get pods -n openshift-storage -o wide | grep ocp-virt4-ceph7 | grep osd

# Real-time CPU monitoring
for pod in $(oc get pods -n openshift-storage -o name | grep rook-ceph-osd | head -3); do
  echo "=== $pod ==="
  oc top -n openshift-storage $pod
done
```

### Check Current OSD Configuration

```bash
# View OSD thread settings
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config show osd.58 | grep -E "thread|op_queue|mclock|bluestore"

# Check resource requests/limits
oc get pods -n openshift-storage -l app=rook-ceph-osd -o json | \
  jq '.items[0].spec.containers[0].resources'
```

---

## Immediate Configuration Changes

### Option 1: Edit CephCluster CR (Recommended)

This updates all OSDs cluster-wide.

```bash
# Edit the CephCluster resource
oc edit cephcluster ocs-storagecluster-cephcluster -n openshift-storage
```

Add the following under `spec.storage.config`:

```yaml
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: ocs-storagecluster-cephcluster
  namespace: openshift-storage
spec:
  storage:
    config:
      # Reduce OSD operation threads (default: 2-4 per OSD)
      osd_op_threads: "2"

      # Reduce recovery threads to lower background CPU
      osd_recovery_threads: "1"
      osd_recovery_op_priority: "1"

      # Limit scrubbing impact
      osd_max_scrubs: "1"
      osd_scrub_sleep: "0.1"

      # Use simpler queue scheduler
      osd_op_queue: "wpq"
      osd_op_queue_cut_off: "low"

      # Reduce BlueStore cache size (reduces memory/CPU churn)
      bluestore_cache_size_hdd: "1073741824"   # 1GB for HDD
      bluestore_cache_size_ssd: "3221225472"   # 3GB for SSD

      # Enable auto-tuning
      osd_mclock_profile: "balanced"
```

**Save and exit.** Rook operator will restart OSDs with new config.

---

### Option 2: Runtime Configuration (Temporary)

Apply immediately without restarting OSDs:

```bash
# Reduce operation threads
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config set osd osd_op_threads 2

# Reduce recovery threads
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config set osd osd_recovery_threads 1

# Limit scrubbing
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config set osd osd_max_scrubs 1

# Use simpler queue
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config set osd osd_op_queue wpq

# Verify changes
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config dump | grep osd_op_threads
```

**Note:** These changes persist but won't survive a cluster rebuild. Use Option 1 for permanent changes.

---

## Resource Limit Solutions

### Set CPU Limits on OSD Pods

Edit the CephCluster CR:

```bash
oc edit cephcluster ocs-storagecluster-cephcluster -n openshift-storage
```

Add resource limits under `spec.resources`:

```yaml
spec:
  resources:
    osd:
      limits:
        cpu: "2"        # Maximum 2 cores per OSD
        memory: "4Gi"   # Maximum 4GB per OSD
      requests:
        cpu: "1"        # Guaranteed 1 core per OSD
        memory: "2Gi"   # Guaranteed 2GB per OSD
```

**Impact:**
- 6 OSDs × 2 CPU limit = 12 cores maximum
- Prevents unlimited CPU consumption
- May throttle OSDs under high load (but prevents crashes)

---

### CPU Affinity and Pinning

Pin OSDs to specific CPU cores to avoid context switching:

```yaml
spec:
  placement:
    osd:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: node-role.kubernetes.io/storage
              operator: Exists
  resources:
    osd:
      limits:
        cpu: "2"
      requests:
        cpu: "2"    # Match limits to guarantee dedicated cores
```

**Best Practice:** Request = Limit ensures guaranteed QoS (no overcommit).

---

## Long-Term Architecture Changes

### 1. Redistribute OSDs Across Nodes

**Current State:** 6 OSDs on ocp-virt4-ceph7
**Target:** 3-4 OSDs per node maximum

#### Steps to Rebalance:

```bash
# 1. Check current distribution
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd tree

# 2. Identify OSDs on ocp-virt4-ceph7 (OSDs: 50, 52, 54, 55, 56, 58)

# 3. Mark OSDs for removal (example: remove OSD 50, 52, 54)
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd out 50
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd out 52
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd out 54

# 4. Wait for data to rebalance (can take hours)
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph -s

# 5. When HEALTH_OK and no rebalancing, remove OSDs
# See: https://rook.io/docs/rook/latest/CRDs/Cluster/ceph-cluster-crd/#osd-configuration
```

**Recommendation:** Keep 3 OSDs per node (50% reduction in CPU load).

---

### 2. Upgrade Node Hardware

**Current Estimated:** 4-6 physical cores (226% with 6 OSDs)
**Recommended:** 12-16 cores minimum

**Calculation:**
- Formula: `(2-3 cores per OSD) + 2 cores for system`
- For 6 OSDs: `(6 × 2) + 2 = 14 cores minimum`
- For 3 OSDs: `(3 × 2) + 2 = 8 cores minimum`

**Check actual CPU count:**

```bash
oc debug node/ocp-virt4-ceph7 -- chroot /host lscpu | grep "^CPU(s):"
```

---

### 3. Separate Storage and Compute Workloads

Add node taints to prevent non-storage workloads:

```bash
# Taint storage nodes
oc adm taint nodes ocp-virt4-ceph7 node-role.kubernetes.io/storage=:NoSchedule

# Update CephCluster to tolerate taint
oc edit cephcluster ocs-storagecluster-cephcluster -n openshift-storage
```

Add toleration:

```yaml
spec:
  placement:
    osd:
      tolerations:
      - key: node-role.kubernetes.io/storage
        operator: Exists
```

---

## Verification Commands

### Monitor CPU Usage After Changes

```bash
# Watch OSD CPU usage (press Ctrl+C to stop)
watch -n 5 'oc top pods -n openshift-storage | grep osd'

# Check node resource allocation
oc describe node ocp-virt4-ceph7 | grep -A 20 "Allocated resources:"

# Verify configuration changes applied
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config show osd.58 | grep -E "osd_op_threads|osd_recovery_threads"
```

### Monitor for OSD Crashes

```bash
# Run continuous monitoring (from toolkit)
cd /Users/prutledg/fix-cnv-paused-vms
./monitor-vms-and-ceph.sh --loop 300

# Check for new crashes
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph crash ls

# Check OSD performance
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd perf
```

### Verify Cluster Health

```bash
# Overall health
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph -s

# OSD status
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd stat

# Check for slow operations
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd perf
```

---

## Recommended Implementation Plan

### Phase 1: Immediate Relief (Today)

1. **Apply thread limits via runtime config** (Option 2 above)
   - `osd_op_threads: 2`
   - `osd_recovery_threads: 1`
   - No restarts required, immediate effect

2. **Monitor for 24 hours**
   ```bash
   ./monitor-vms-and-ceph.sh --loop 300 --webhook YOUR_SLACK_WEBHOOK
   ```

3. **Expected Result:** CPU overcommit drops to ~150%

---

### Phase 2: Persistent Configuration (This Week)

1. **Update CephCluster CR** (Option 1 above)
   - Makes thread limits permanent
   - Add resource limits (cpu: "2")

2. **Rolling restart of OSDs** (automatic via Rook)
   - Rook restarts OSDs one at a time
   - Monitor with: `oc get pods -n openshift-storage -w`

3. **Expected Result:** CPU overcommit drops to ~120-130%

---

### Phase 3: Architecture Changes (Next Month)

1. **Option A: Reduce OSDs per node** (3 instead of 6)
   - Rebalance OSDs across more nodes
   - Requires capacity planning

2. **Option B: Upgrade node hardware** (add 8+ cores)
   - Most straightforward
   - May require budget approval

3. **Expected Result:** CPU overcommit drops to ~80-100%

---

## Troubleshooting

### OSDs Keep Crashing After Changes

```bash
# Check if config applied
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config show osd.58

# Check OSD logs
oc logs -n openshift-storage rook-ceph-osd-58-xxxxx --tail=200

# Run node diagnostics
cd /Users/prutledg/fix-cnv-paused-vms
./diagnose-node.sh ocp-virt4-ceph7
```

### Configuration Not Applied

```bash
# Restart specific OSD pod to force reload
oc delete pod -n openshift-storage rook-ceph-osd-58-xxxxx

# Or restart Rook operator to trigger reconciliation
oc delete pod -n openshift-storage -l app=rook-ceph-operator
```

### Performance Degradation After Limits

If storage performance drops unacceptably:

```bash
# Increase thread limits slightly
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config set osd osd_op_threads 3

# Or use high_client_ops profile
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config set osd osd_mclock_profile high_client_ops
```

---

## References

- [Ceph OSD Configuration Reference](https://docs.ceph.com/en/latest/rados/configuration/osd-config-ref/)
- [Rook CephCluster CRD](https://rook.io/docs/rook/latest/CRDs/Cluster/ceph-cluster-crd/)
- [BlueStore Configuration](https://docs.ceph.com/en/latest/rados/configuration/bluestore-config-ref/)
- [Ceph mClock QoS](https://docs.ceph.com/en/latest/rados/configuration/mclock-config-ref/)

---

## Summary

**Quick Win:** Apply thread limits via runtime config (reduces CPU 20-30%)
**Sustainable:** Update CephCluster CR with limits (reduces CPU 40-50%)
**Long-term:** Reduce OSDs per node or upgrade hardware (reduces CPU 60-70%)

**Expected Timeline:**
- Immediate relief: 1 hour
- Persistent config: 1 day (includes OSD restarts)
- Architecture change: 2-4 weeks (requires planning)

**Monitor continuously:**
```bash
cd /Users/prutledg/fix-cnv-paused-vms
./monitor-vms-and-ceph.sh --loop 300
```
