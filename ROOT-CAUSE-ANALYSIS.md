# Root Cause Analysis: VM Pauses Due to Ceph OSD Crashes

**Date:** 2026-01-28  
**Incident:** 124 VMs paused cluster-wide due to IO errors  
**Duration:** ~7 hours (04:59 - 12:01 UTC crashes, VMs paused until ~17:30 UTC)  
**Impact:** 124 VMs across all namespaces, production workloads affected  

---

## Executive Summary

A single Ceph storage node (`ocp-virt4-ceph7`) experienced cascading OSD failures that triggered a cluster-wide VM pause event affecting 124 virtual machines. The root cause was isolated to **one physical node experiencing issues that caused 60% of its OSDs to crash repeatedly** over a 7-hour period.

---

## Timeline

| Time (UTC) | Event |
|------------|-------|
| 04:59 | First OSD crashes detected (OSD.50, OSD.52, OSD.58) on ocp-virt4-ceph7 |
| 05:00-10:46 | OSD.58 crashes 10 times, other OSDs crash sporadically |
| 10:12-12:01 | Additional OSDs crash (OSD.54, OSD.55, OSD.56, OSD.51) |
| 12:01 | Last OSD crash (OSD.50) |
| 14:41 | Node ocp-virt4-ceph7 transitions to Ready state |
| 14:56 | Ceph cluster health changes from HEALTH_WARN → HEALTH_OK |
| 00:23 (next day) | VMs start pausing due to IO errors |
| 00:48-00:50 | Nodes get blocklisted by CSI RBD plugin |
| 01:00-02:00 | Manual intervention: blocklists cleared, VMs restarted |

---

## Root Cause

### Primary Cause
**Single Node Failure:** `ocp-virt4-ceph7` experienced instability that caused 6 out of 10 OSDs to crash.

### Affected OSDs
Node `ocp-virt4-ceph7` hosts 10 OSDs (50-58, 68):
- **OSD.58**: 10 crashes (worst offender)
- **OSD.50**: 3 crashes
- **OSD.52**: 3 crashes  
- **OSD.54**: 2 crashes
- **OSD.55**: 2 crashes
- **OSD.56**: 1 crash
- **Total**: 21 crashes affecting 60% of OSDs on one node

### Crash Pattern
All crashes show the same backtrace pattern:
```
BlueStore::_txc_create → handle_watch_timeout
```

This indicates **watch operations timing out**, typically caused by:
1. Slow disk I/O
2. Network latency/instability
3. Resource contention
4. Hardware issues

### Cascade Effect

```
Node Issue (ocp-virt4-ceph7)
    ↓
OSD Crashes (50, 52, 54, 55, 56, 58)
    ↓
Ceph Cluster HEALTH_WARN
    ↓
VM IO Errors (delayed ~12 hours)
    ↓
VMs Auto-Pause for Safety
    ↓
CSI Plugin Blocklists Nodes
    ↓
Blocklist Prevents Volume Reattachment
    ↓
124 VMs Paused Cluster-Wide
```

---

## Technical Details

### Node Information
- **Node:** ocp-virt4-ceph7
- **OSDs Hosted:** 10 (IDs: 50, 51, 52, 53, 54, 55, 56, 57, 58, 68)
- **Capacity:** 80 CPUs, 387GB RAM
- **CPU Overcommit:** 226% (potential concern)
- **Status:** Recovered at 14:41 UTC

### Crash Analysis
**Sample Backtrace (OSD.58):**
```
BlueStore::_txc_create
  → BlueStore::queue_transactions
  → ReplicatedBackend::submit_transaction
  → PrimaryLogPG::issue_repop
  → PrimaryLogPG::handle_watch_timeout
```

**Interpretation:**
- Watch timeout in BlueStore transaction creation
- Suggests slow storage backend (disk I/O)
- Possible causes: disk latency, network issues, resource starvation

### Why VMs Paused

1. **OSD crashes** caused temporary Ceph cluster degradation
2. Some VM disk operations experienced **IO timeouts**
3. **KubeVirt safety mechanism** paused VMs to prevent data corruption
4. **CSI RBD plugin** blocklisted affected nodes to fence stale connections
5. **Blocklist prevented** volume reattachment, causing persistent IO errors

---

## Why It Took So Long to Manifest

The OSD crashes occurred in the morning (04:59-12:01 UTC), but VMs didn't pause until midnight (00:23 UTC the next day). Why?

### Ceph's Resilience Mechanisms
1. **Replication**: Data is replicated (size=2), so one OSD failing doesn't immediately break access
2. **Recovery**: Ceph automatically rebalances and recovers from OSD failures
3. **Buffering**: Client operations can be buffered during brief disruptions

### The Breaking Point
- Multiple OSDs on the same node crashed repeatedly
- Some VMs may have had data primarily on the affected OSDs
- Eventually, watch timeouts accumulated beyond recovery thresholds
- VMs hit unrecoverable IO errors and paused for safety

---

## Investigation Questions

### What Happened to ocp-virt4-ceph7?

**Possibilities:**
1. **Network instability** - Network partition or latency spike
2. **Disk issues** - Slow disk, failing disk, or RAID degradation
3. **Resource exhaustion** - CPU/memory contention (226% CPU overcommit)
4. **Hardware problem** - Memory errors, NIC issues, backplane problems
5. **Kernel/OS issue** - Kernel panic, driver bug, filesystem issue

**Evidence to collect:**
```bash
# Check node logs around 04:59-12:01 UTC on Jan 28
oc debug node/ocp-virt4-ceph7 -- journalctl --since "2026-01-28 04:00" --until "2026-01-28 13:00"

# Check for hardware errors
oc debug node/ocp-virt4-ceph7 -- chroot /host dmesg | grep -i error

# Check disk health
oc debug node/ocp-virt4-ceph7 -- chroot /host smartctl -a /dev/sd*

# Check network errors
oc debug node/ocp-virt4-ceph7 -- chroot /host ip -s link
```

### Why Did 226% CPU Overcommit Matter?

While Kubernetes allows CPU overcommit, this means:
- 79.5 cores allocated vs 179.71 cores requested (limits)
- During high load, processes compete for CPU
- OSD processes may not get CPU when needed
- Leads to missed heartbeats and watch timeouts

---

## Resolution Steps Taken

1. ✅ Identified 124 paused VMs across cluster
2. ✅ Verified Ceph cluster health (HEALTH_OK)
3. ✅ Removed Ceph blocklist entries (35 initially, targeted clearing implemented)
4. ✅ Restarted virt-launcher pods in batches (10 VMs/batch, 60s delay)
5. ✅ Verified all VMs recovered successfully

---

## Prevention Recommendations

### Immediate Actions (High Priority)

1. **Investigate ocp-virt4-ceph7**
   - Check hardware health (disks, memory, NIC)
   - Review system logs for errors
   - Monitor for recurring issues
   - Consider replacing/repairing if hardware fault detected

2. **Archive Ceph Crash Reports**
   ```bash
   oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph crash archive-all
   ```

3. **Monitor Affected OSDs**
   ```bash
   oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph tell osd.58 bench
   ```

4. **Review CPU Overcommit**
   - 226% overcommit on storage nodes is risky
   - Consider reducing OSD resource limits or moving workloads

### Short-term (1-2 weeks)

1. **Implement Monitoring**
   - Alert on OSD crashes
   - Alert on Ceph HEALTH_WARN
   - Alert on paused VMs
   - Monitor ocp-virt4-ceph7 metrics closely

2. **Increase Watch Timeout** (if appropriate)
   ```bash
   # Current: 20 seconds
   # Consider: 30-60 seconds for slower storage
   ceph config set osd osd_heartbeat_grace 30
   ```

3. **Review OSD Distribution**
   - Consider rebalancing OSDs if one node has disproportionate load
   - Ensure CRUSH rules distribute load evenly

4. **Capacity Planning**
   - Current usage: 100 TiB / 244 TiB (41%)
   - Monitor growth trends
   - Plan for capacity expansion

### Long-term (1-3 months)

1. **Automated Recovery**
   - Deploy the fix-paused-vms.sh script as a cron job or operator
   - Alert on-call team when VMs pause

2. **Improve OSD Resilience**
   - Review BlueStore configuration
   - Consider SSD caching for metadata
   - Tune RocksDB compaction settings

3. **Node Health Checks**
   - Implement periodic hardware health checks
   - Add SMART monitoring for disks
   - Check for firmware updates

4. **Disaster Recovery Testing**
   - Test OSD failure scenarios
   - Verify VM recovery procedures
   - Document runbooks

---

## Lessons Learned

### What Worked Well
✅ Ceph replication prevented data loss  
✅ VM pause mechanism prevented corruption  
✅ Cluster ultimately self-healed  
✅ Systematic batch restart recovered all VMs  

### What Could Be Improved
⚠️ No alerting on OSD crashes  
⚠️ No monitoring for paused VMs  
⚠️ Delayed detection (~12 hours)  
⚠️ Manual intervention required  
⚠️ No automatic blocklist clearing  

### Key Takeaways
1. **Single node failure** can have cluster-wide impact
2. **Watch timeouts** are often symptomatic of underlying I/O issues
3. **CPU overcommit** on storage nodes can cause instability
4. **Blocklisting** is a safety mechanism but requires manual clearing
5. **Monitoring gaps** allowed issue to escalate undetected

---

## Related Resources

- **Recovery Script:** `fix-cnv-paused-vms/fix-paused-vms.sh`
- **Incident Logs:** `/tmp/vm-recovery-*.log`
- **Ceph Documentation:** https://docs.ceph.com/
- **ODF Documentation:** https://access.redhat.com/documentation/en-us/red_hat_openshift_data_foundation

---

## Appendix: Useful Commands

### Check Ceph Health
```bash
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph -s
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph health detail
```

### Check OSD Status
```bash
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd tree
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd df
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd perf
```

### Check Crashes
```bash
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph crash ls
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph crash info <crash-id>
```

### Check Paused VMs
```bash
oc get vmi --all-namespaces -o json | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Paused" and .status=="True")) | "\(.metadata.namespace)/\(.metadata.name)"'
```

### Check Blocklist
```bash
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd blocklist ls
```

---

**Document Version:** 1.0  
**Last Updated:** 2026-01-29  
**Author:** Claude (Automated RCA)
