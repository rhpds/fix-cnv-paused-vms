# Reducing OSD CPU Overcommit

**Problem:** Node ocp-virt4-ceph7 shows 226% CPU overcommit with 6 OSDs, causing OSD crashes and VM pauses.

**Root Cause:** BlueStore watch timeouts during high CPU contention on ocp-virt4-ceph7.

**Goal:** Reduce CPU overcommit to 100-150% through configuration tuning.

---

## ⚠️ IMPORTANT: Operator-Managed Environment

This cluster uses **OpenShift Data Foundation (ODF)** with the **Rook-Ceph operator**.

**Critical Guidelines:**
- ✅ **DO:** Make changes through the `CephCluster` or `StorageCluster` Custom Resources (CRs)
- ❌ **DON'T:** Make direct changes to Ceph config or pod specs - the operator will override them
- ⚠️ **Runtime config changes** (`ceph config set`) are **temporary** and will be lost when:
  - OSD pods are restarted
  - Operator reconciles the cluster
  - Cluster is upgraded

**All permanent changes MUST go through the operator's CRs.**

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

### Step 1: Find Your CephCluster Resource

```bash
# List all CephCluster resources
oc get cephcluster -n openshift-storage

# Common names:
# - ocs-storagecluster-cephcluster (ODF 4.x)
# - cephcluster (older versions)

# Export for easy reference
export CEPH_CLUSTER=$(oc get cephcluster -n openshift-storage -o name | head -1)
echo "Using: $CEPH_CLUSTER"
```

### Step 2: Check Current Configuration

```bash
# View current CephCluster spec
oc get $CEPH_CLUSTER -n openshift-storage -o yaml | less

# Check if storage.config section exists
oc get $CEPH_CLUSTER -n openshift-storage -o jsonpath='{.spec.storage.config}' | jq '.'

# Check current resource limits
oc get $CEPH_CLUSTER -n openshift-storage -o jsonpath='{.spec.resources.osd}' | jq '.'
```

### Step 3: Apply Thread Configuration (Permanent)

**Method A: Using `oc patch` (Safer - less chance of errors)**

```bash
# Patch the CephCluster to add Ceph configuration
oc patch $CEPH_CLUSTER -n openshift-storage --type=merge -p '
{
  "spec": {
    "storage": {
      "config": {
        "osd_op_threads": "2",
        "osd_recovery_threads": "1",
        "osd_recovery_op_priority": "1",
        "osd_max_scrubs": "1",
        "osd_scrub_sleep": "0.1",
        "osd_op_queue": "wpq",
        "osd_op_queue_cut_off": "low",
        "bluestore_cache_size_hdd": "1073741824",
        "bluestore_cache_size_ssd": "3221225472",
        "osd_mclock_profile": "balanced"
      }
    }
  }
}'
```

**Method B: Using `oc edit` (Interactive)**

```bash
# Edit the CephCluster resource interactively
oc edit $CEPH_CLUSTER -n openshift-storage
```

Add or modify the `spec.storage.config` section:

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

**Save and exit.** The Rook operator will:
1. Detect the change within ~60 seconds
2. Update the OSD ConfigMap
3. Restart OSDs one by one (rolling restart)
4. Each OSD restart takes ~2-5 minutes

### Step 4: Monitor Operator Reconciliation

```bash
# Watch the operator processing the change
oc logs -n openshift-storage -l app=rook-ceph-operator -f --tail=50

# Watch OSD pods restarting (one at a time)
watch -n 5 'oc get pods -n openshift-storage | grep rook-ceph-osd'

# Check Ceph health during the update
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph -s
```

**Expected behavior:**
- Operator logs will show "updating OSD deployment"
- OSDs restart one at a time (not all at once)
- Ceph health may briefly show HEALTH_WARN during restarts
- Total time: 30-60 minutes for all OSDs

---

### ⚠️ Runtime Configuration (Emergency Only - NOT RECOMMENDED)

**WARNING:** Runtime config changes will be **LOST** when:
- OSD pods restart (any reason)
- Operator reconciles the cluster
- Cluster is upgraded or scaled

**Only use this for emergency situations before applying the permanent fix above.**

```bash
# Emergency immediate relief (temporary)
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config set osd osd_op_threads 2

oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config set osd osd_recovery_threads 1

# Verify (will be lost on next OSD restart)
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config dump | grep -E "osd_op_threads|osd_recovery_threads"
```

**After applying emergency config, immediately apply the permanent fix using Step 3 above.**

---

## Resource Limit Solutions

### Set CPU Limits on OSD Pods (Via Operator)

**Method A: Using `oc patch`**

```bash
# Get current resource limits first
oc get $CEPH_CLUSTER -n openshift-storage -o jsonpath='{.spec.resources.osd}' | jq '.'

# Patch with new CPU limits (conservative approach)
oc patch $CEPH_CLUSTER -n openshift-storage --type=merge -p '
{
  "spec": {
    "resources": {
      "osd": {
        "limits": {
          "cpu": "2",
          "memory": "4Gi"
        },
        "requests": {
          "cpu": "1",
          "memory": "2Gi"
        }
      }
    }
  }
}'
```

**Method B: Using `oc edit`**

```bash
# Edit the CephCluster resource
oc edit $CEPH_CLUSTER -n openshift-storage
```

Add or modify `spec.resources.osd`:

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
- 10 OSDs × 2 CPU limit = 20 cores maximum (down from 40)
- Reduces CPU overcommit from 226% to ~120-130%
- Prevents unlimited CPU consumption
- May throttle OSDs under high load (but prevents crashes)

**Monitor the change:**
```bash
# Watch operator apply changes
oc get pods -n openshift-storage -l app=rook-ceph-osd -w

# Verify new limits are applied
oc get pods -n openshift-storage -l app=rook-ceph-osd -o json | \
  jq '.items[0].spec.containers[0].resources'
```

---

### CPU Affinity and Guaranteed QoS (Via Operator)

For best performance, match CPU requests and limits (guaranteed QoS):

```bash
# Patch for guaranteed QoS (no overcommit)
oc patch $CEPH_CLUSTER -n openshift-storage --type=merge -p '
{
  "spec": {
    "resources": {
      "osd": {
        "limits": {
          "cpu": "2",
          "memory": "4Gi"
        },
        "requests": {
          "cpu": "2",
          "memory": "4Gi"
        }
      }
    }
  }
}'
```

Or via `oc edit`:

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
        memory: "4Gi"
      requests:
        cpu: "2"        # Match limits = guaranteed QoS
        memory: "4Gi"   # Match limits = guaranteed QoS
```

**Best Practice:** Request = Limit ensures:
- Pods get guaranteed CPU cores (no sharing)
- QoS class = Guaranteed (highest priority)
- No CPU throttling under normal conditions
- Predictable performance

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

### 1. Verify Operator Applied Changes to CephCluster CR

```bash
# Check if your changes are in the CephCluster spec
oc get $CEPH_CLUSTER -n openshift-storage -o yaml | grep -A 20 "storage:"

# Check resource limits in CR
oc get $CEPH_CLUSTER -n openshift-storage -o jsonpath='{.spec.resources.osd}' | jq '.'

# Check Ceph config in CR
oc get $CEPH_CLUSTER -n openshift-storage -o jsonpath='{.spec.storage.config}' | jq '.'
```

### 2. Verify Operator Propagated Changes to Pods

```bash
# Check if OSD pods have new resource limits
oc get pods -n openshift-storage -l app=rook-ceph-osd -o json | \
  jq '.items[0].spec.containers[0].resources'

# Verify all OSDs have the same limits
oc get pods -n openshift-storage -l app=rook-ceph-osd -o json | \
  jq -r '.items[] | "\(.metadata.name): \(.spec.containers[0].resources.limits.cpu)"'
```

### 3. Verify Ceph Runtime Configuration

```bash
# Check if Ceph config matches CephCluster CR
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config show osd.58 | grep -E "osd_op_threads|osd_recovery_threads|osd_op_queue"

# Check all OSDs have the same config
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config dump | grep -E "osd_op_threads|osd_recovery_threads"
```

### 4. Monitor CPU Usage After Changes

```bash
# Watch OSD CPU usage (press Ctrl+C to stop)
watch -n 5 'oc top pods -n openshift-storage | grep osd'

# Check node resource allocation
oc describe node ocp-virt4-ceph7 | grep -A 20 "Allocated resources:"

# Check if overcommit improved
oc describe node ocp-virt4-ceph7 | grep -E "cpu.*%"
```

### 5. Check Operator Logs for Issues

```bash
# Watch operator processing changes
oc logs -n openshift-storage -l app=rook-ceph-operator --tail=100 -f

# Check for errors in operator
oc logs -n openshift-storage -l app=rook-ceph-operator --tail=500 | grep -i error

# Check ODF operator (if using ODF)
oc logs -n openshift-storage -l name=ocs-operator --tail=100 -f
```

### Monitor for OSD Crashes

```bash
# Run continuous monitoring (from toolkit)
# Run from toolkit directory
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

### Phase 1: Immediate Relief (Today) - Via Operator

**⚠️ IMPORTANT:** All changes must go through the CephCluster CR to survive operator reconciliation.

1. **Backup current configuration**
   ```bash
   oc get $CEPH_CLUSTER -n openshift-storage -o yaml > cephcluster-backup-$(date +%Y%m%d).yaml
   ```

2. **Apply thread limits via CephCluster CR**
   ```bash
   oc patch $CEPH_CLUSTER -n openshift-storage --type=merge -p '
   {
     "spec": {
       "storage": {
         "config": {
           "osd_op_threads": "2",
           "osd_recovery_threads": "1"
         }
       }
     }
   }'
   ```

3. **Monitor operator applying changes** (30-60 minutes)
   ```bash
   # Watch operator logs
   oc logs -n openshift-storage -l app=rook-ceph-operator -f --tail=50

   # Watch OSD pods restarting one by one
   oc get pods -n openshift-storage -l app=rook-ceph-osd -w
   ```

4. **Verify changes applied**
   ```bash
   oc exec -n openshift-storage deploy/rook-ceph-tools -- \
     ceph config show osd.58 | grep osd_op_threads
   ```

5. **Monitor for 24-48 hours**
   ```bash
   ./monitor-vms-and-ceph.sh --loop 300 --webhook YOUR_SLACK_WEBHOOK
   ```

**Expected Result:** Reduced CPU contention, fewer thread context switches

---

### Phase 2: Add Resource Limits (This Week) - Via Operator

1. **Apply CPU limits via CephCluster CR**
   ```bash
   oc patch $CEPH_CLUSTER -n openshift-storage --type=merge -p '
   {
     "spec": {
       "resources": {
         "osd": {
           "limits": {"cpu": "2", "memory": "4Gi"},
           "requests": {"cpu": "1", "memory": "2Gi"}
         }
       }
     }
   }'
   ```

2. **Monitor rolling restart** (automatic via Rook)
   - Rook restarts OSDs one at a time
   - Each restart: 2-5 minutes
   - Total time: 30-60 minutes for all OSDs

3. **Verify new limits applied**
   ```bash
   oc get pods -n openshift-storage -l app=rook-ceph-osd -o json | \
     jq '.items[0].spec.containers[0].resources'
   ```

4. **Check node resource allocation**
   ```bash
   oc describe node ocp-virt4-ceph7 | grep -A 5 "Allocated resources"
   ```

**Expected Result:** CPU overcommit drops from 226% to ~120-130%

---

### Phase 3: Architecture Changes (Next Month)

1. **Option A: Reduce OSDs per node** (keep 3-4, remove 6-7)
   - Rebalance OSDs across more nodes
   - Requires capacity planning
   - See "Long-Term Architecture Changes" section below

2. **Option B: Upgrade node hardware** (add more CPU cores)
   - Upgrade to 2× 32-core CPUs (128 threads)
   - Most straightforward but costly
   - May require budget approval

3. **Option C: Hybrid approach**
   - Keep 4 OSDs on this node with limits
   - Add 2 new storage nodes
   - Spread remaining OSDs across new nodes

**Expected Result:** CPU overcommit drops to ~80-100%

---

### Emergency Procedure (If Incident Occurs Again)

If OSDs start crashing before permanent fix is applied:

```bash
# 1. Emergency temporary relief (will be lost on restart)
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config set osd osd_op_threads 2

# 2. Immediately apply permanent fix via operator
oc patch $CEPH_CLUSTER -n openshift-storage --type=merge -p '
{
  "spec": {
    "storage": {
      "config": {
        "osd_op_threads": "2"
      }
    }
  }
}'

# 3. If VMs are paused, run recovery
# Run from toolkit directory
./fix-paused-vms.sh -y
```

---

## Troubleshooting

### Changes Not Applied by Operator

**Problem:** You updated the CephCluster CR but OSDs still have old config.

```bash
# 1. Check if changes are in the CR
oc get $CEPH_CLUSTER -n openshift-storage -o yaml | grep -A 20 "storage:"

# 2. Check operator logs for errors
oc logs -n openshift-storage -l app=rook-ceph-operator --tail=200 | grep -i error

# 3. Check if operator is reconciling
oc logs -n openshift-storage -l app=rook-ceph-operator --tail=50 | grep -i "updating osd"

# 4. Force operator reconciliation (restart operator)
oc delete pod -n openshift-storage -l app=rook-ceph-operator

# 5. Wait 2-3 minutes, then check if OSDs are being updated
oc get pods -n openshift-storage -l app=rook-ceph-osd -w
```

**Common causes:**
- Operator is stuck or crashed
- Conflicting StorageCluster CR settings (ODF)
- Validation errors in CephCluster spec
- Operator doesn't have permissions

### Operator Reverts Your Changes

**Problem:** Changes are applied but then reverted back.

```bash
# Check if StorageCluster CR is overriding CephCluster
oc get storagecluster -n openshift-storage -o yaml | grep -A 20 "resources:"

# If using ODF, you may need to update StorageCluster instead
oc edit storagecluster -n openshift-storage
```

**Solution:** With ODF, some settings must be made in `StorageCluster` CR, not `CephCluster` CR.

```bash
# Check which CR controls your cluster
oc get storagecluster -n openshift-storage

# If StorageCluster exists, update it instead:
oc patch storagecluster ocs-storagecluster -n openshift-storage --type=merge -p '
{
  "spec": {
    "resources": {
      "osd": {
        "limits": {"cpu": "2", "memory": "4Gi"},
        "requests": {"cpu": "1", "memory": "2Gi"}
      }
    }
  }
}'
```

### OSDs Keep Crashing After Changes

```bash
# 1. Verify config actually changed in Ceph
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph config show osd.58 | grep -E "thread|queue|mclock"

# 2. Check if limits are too aggressive
oc get pods -n openshift-storage -l app=rook-ceph-osd -o json | \
  jq '.items[0].spec.containers[0].resources'

# 3. Check OSD logs for new error patterns
oc logs -n openshift-storage rook-ceph-osd-58-xxxxx --tail=500 | grep -i error

# 4. Run full node diagnostics
# Run from toolkit directory
./diagnose-node.sh ocp-virt4-ceph7
```

**If crashes continue:**
- Limits may be too low (try cpu: "3" instead of "2")
- Thread count may be too low (try "3" instead of "2")
- May indicate hardware issue (check diagnostics output)

### Performance Degradation After Limits

If storage performance drops unacceptably after applying limits:

```bash
# 1. Check if OSDs are being CPU throttled
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd perf

# 2. Slightly increase thread limits via CephCluster CR
oc patch $CEPH_CLUSTER -n openshift-storage --type=merge -p '
{
  "spec": {
    "storage": {
      "config": {
        "osd_op_threads": "3"
      }
    }
  }
}'

# 3. Or switch to high performance mClock profile
oc patch $CEPH_CLUSTER -n openshift-storage --type=merge -p '
{
  "spec": {
    "storage": {
      "config": {
        "osd_mclock_profile": "high_client_ops"
      }
    }
  }
}'
```

**Note:** Always make changes through the CephCluster CR, not with `ceph config set`.

### Operator Logs Show Errors

```bash
# Get recent operator errors
oc logs -n openshift-storage -l app=rook-ceph-operator --tail=500 | grep -E "ERROR|error"

# Common errors and solutions:

# "failed to reconcile": Operator can't apply changes
# Solution: Check CR validation with `oc get cephcluster -o yaml`

# "validation failed": Invalid config values
# Solution: Check Ceph config parameter names and values

# "permission denied": RBAC issues
# Solution: Check operator ServiceAccount permissions
```

---

## References

- [Ceph OSD Configuration Reference](https://docs.ceph.com/en/latest/rados/configuration/osd-config-ref/)
- [Rook CephCluster CRD](https://rook.io/docs/rook/latest/CRDs/Cluster/ceph-cluster-crd/)
- [BlueStore Configuration](https://docs.ceph.com/en/latest/rados/configuration/bluestore-config-ref/)
- [Ceph mClock QoS](https://docs.ceph.com/en/latest/rados/configuration/mclock-config-ref/)

---

## Summary

### Operator-First Approach (REQUIRED)

**All changes MUST be made through Custom Resources to survive operator reconciliation:**

1. **Thread Configuration** (via CephCluster CR)
   - `osd_op_threads: "2"`
   - `osd_recovery_threads: "1"`
   - Reduces CPU 20-30%
   - Takes effect after OSD rolling restart (30-60 min)

2. **Resource Limits** (via CephCluster or StorageCluster CR)
   - `cpu: "2"` limit per OSD
   - Reduces CPU overcommit from 226% to ~120-130%
   - Takes effect after OSD rolling restart (30-60 min)

3. **Long-term Architecture** (via cluster design)
   - Reduce OSDs per node (3-4 instead of 10)
   - Or upgrade node hardware (more CPU cores)
   - Reduces CPU overcommit to ~80-100%

### Expected Timeline

| Phase | Method | Time | Result |
|-------|--------|------|--------|
| **Phase 1** | Update CephCluster CR with thread limits | 1-2 hours (includes rolling restart) | Reduced CPU contention |
| **Phase 2** | Add resource limits to CephCluster CR | 1-2 hours (includes rolling restart) | CPU overcommit: 226% → 120-130% |
| **Phase 3** | Redistribute OSDs or upgrade hardware | 2-4 weeks | CPU overcommit: 120% → 80-100% |

### Key Commands

```bash
# Find your CephCluster
export CEPH_CLUSTER=$(oc get cephcluster -n openshift-storage -o name | head -1)

# Apply thread configuration
oc patch $CEPH_CLUSTER -n openshift-storage --type=merge -p '
{"spec":{"storage":{"config":{"osd_op_threads":"2"}}}}'

# Apply resource limits
oc patch $CEPH_CLUSTER -n openshift-storage --type=merge -p '
{"spec":{"resources":{"osd":{"limits":{"cpu":"2","memory":"4Gi"}}}}}'

# Monitor continuously
# Run from toolkit directory
./monitor-vms-and-ceph.sh --loop 300
```

### ⚠️ What NOT to Do

- ❌ Don't use `ceph config set` for permanent changes (operator will override)
- ❌ Don't edit OSD pod specs directly (operator will override)
- ❌ Don't edit OSD deployments (operator will override)
- ✅ **Always** use CephCluster or StorageCluster CRs for permanent changes
