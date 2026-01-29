# OpenShift VM Recovery Tool

## Overview
This script recovers VMs that are paused due to Ceph blocklist issues in OpenShift Virtualization clusters.

## Prerequisites
- `oc` CLI installed and logged into an OpenShift cluster
- `jq` command-line JSON processor
- Cluster admin or appropriate permissions
- OpenShift Virtualization (KubeVirt) installed
- Ceph/ODF storage with rook-ceph-tools deployment

## Installation

```bash
# Copy the script to your system
chmod +x fix-paused-vms.sh

# Verify prerequisites
./fix-paused-vms.sh -h
```

## Usage

### Basic Usage
```bash
# Run with defaults (10 VMs per batch, 60s delay)
./fix-paused-vms.sh

# Run with confirmations skipped (automated mode)
./fix-paused-vms.sh -y
```

### Advanced Usage
```bash
# Fix only VMs in specific namespace
./fix-paused-vms.sh -n my-namespace

# Adjust batch size and delay
./fix-paused-vms.sh -b 20 -d 30

# Use custom storage namespace
./fix-paused-vms.sh -s rook-ceph

# Combine options
./fix-paused-vms.sh -n sandbox-jsdhh-ocp4-cluster -b 5 -d 120 -y
```

## What It Does

1. **Prerequisites Check**
   - Verifies `oc` and `jq` are installed
   - Confirms cluster login
   - Validates storage namespace exists

2. **Ceph Health Check**
   - Checks Ceph cluster health status
   - Warns if cluster is not HEALTH_OK

3. **Clear Blocklist**
   - Identifies blocklisted client IPs
   - Removes all blocklist entries
   - Logs each removal

4. **Find Paused VMs**
   - Scans for VMs with Paused=True condition
   - Lists affected VMs

5. **Restart VMs**
   - Deletes virt-launcher pods in batches
   - Allows time between batches for cluster stability
   - Tracks success/failure

6. **Verify Recovery**
   - Waits for VMs to stabilize
   - Reports remaining paused VMs

## Options Reference

| Option | Description | Default |
|--------|-------------|---------|
| `-b, --batch-size` | VMs to restart per batch | 10 |
| `-d, --delay` | Seconds between batches | 60 |
| `-n, --namespace` | Target namespace only | all namespaces |
| `-s, --storage-namespace` | Ceph storage namespace | openshift-storage |
| `-y, --yes` | Skip confirmations | false |
| `-h, --help` | Show help | - |

## Examples

### Conservative Approach (Production)
```bash
# Small batches with longer delays
./fix-paused-vms.sh -b 5 -d 120
```

### Balanced Approach (Default)
```bash
# Medium batches with standard delay
./fix-paused-vms.sh -b 10 -d 60
```

### Aggressive Approach (Development)
```bash
# Large batches with short delay
./fix-paused-vms.sh -b 20 -d 30 -y
```

### Single Namespace
```bash
# Fix only VMs in specific namespace
./fix-paused-vms.sh -n my-project -b 5 -d 60
```

## Logging

All operations are logged to timestamped files:
```
/tmp/vm-recovery-YYYYMMDD-HHMMSS.log
```

The script outputs the log location at startup.

## Troubleshooting

### "No paused VMs found"
This is good! Nothing to fix.

### "Ceph cluster health issue"
The script will prompt whether to continue. Review Ceph health before proceeding:
```bash
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph -s
```

### "Pod not found" warnings
Normal if VMs were already restarted or deleted. The script continues.

### VMs still paused after recovery
Some VMs may need additional time. Wait 2-3 minutes and check:
```bash
oc get vmi --all-namespaces | grep False
```

If still paused, investigate individual VM:
```bash
oc describe vmi <vm-name> -n <namespace>
oc logs -n <namespace> virt-launcher-<vm-name>-xxxxx
```

## Root Cause

This issue typically occurs when:
1. Ceph OSDs crash or timeout
2. VMs experience IO errors and pause automatically
3. CSI RBD plugin blocklists nodes to prevent data corruption
4. Blocklist prevents volume reattachment, causing persistent IO failures

## Prevention

Monitor for underlying issues:
```bash
# Check Ceph health
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph health detail

# Check OSD crashes
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph crash ls

# Monitor OSD logs
oc logs -n openshift-storage -l app=rook-ceph-osd --tail=100
```

## Support

For issues or questions:
1. Check the log file for detailed error messages
2. Verify Ceph cluster health
3. Review individual VM/pod logs
4. Check node conditions and resource availability

## License

Use freely. No warranty provided.
