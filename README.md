# OpenShift CNV Paused VM Recovery Toolkit

Complete toolkit for recovering paused VMs and investigating Ceph OSD issues in OpenShift Virtualization environments.

## 📦 Scripts Included

| Script | Purpose |
|--------|---------|
| **fix-paused-vms.sh** | Recovers VMs paused due to Ceph blocklist issues |
| **monitor-vms-and-ceph.sh** | Continuous monitoring with automated alerting |
| **diagnose-node.sh** | Deep diagnostic analysis of node health |
| **investigate-incident.sh** | Automated post-mortem for the 2026-01-28 incident |
| **ROOT-CAUSE-ANALYSIS.md** | Complete incident report and analysis |

---

## Prerequisites
- `oc` CLI installed and logged into an OpenShift cluster
- `jq` command-line JSON processor
- Cluster admin or appropriate permissions
- OpenShift Virtualization (KubeVirt) installed
- Ceph/ODF storage with rook-ceph-tools deployment

---

## 1️⃣ fix-paused-vms.sh - VM Recovery

### Quick Start
```bash
# Basic usage
./fix-paused-vms.sh

# Automated (no prompts)
./fix-paused-vms.sh -y
```

### What It Does
1. ✅ Finds all paused VMs
2. ✅ Identifies nodes hosting paused VMs
3. ✅ **Clears Ceph blocklist ONLY for affected nodes** (safe!)
4. ✅ Restarts VMs in batches
5. ✅ Verifies recovery

**IMPORTANT:** Script only clears blocklist entries for nodes with paused VMs, not all entries.

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-b, --batch-size` | VMs to restart per batch | 10 |
| `-d, --delay` | Seconds between batches | 60 |
| `-n, --namespace` | Target namespace only | all namespaces |
| `-s, --storage-namespace` | Ceph storage namespace | openshift-storage |
| `-y, --yes` | Skip confirmations | false |
| `-h, --help` | Show help | - |

### Examples

```bash
# Conservative (production)
./fix-paused-vms.sh -b 5 -d 120

# Balanced (default)
./fix-paused-vms.sh -b 10 -d 60

# Aggressive (dev/test)
./fix-paused-vms.sh -b 20 -d 30 -y

# Single namespace
./fix-paused-vms.sh -n my-namespace
```

### Logging
All operations logged to: `/tmp/vm-recovery-YYYYMMDD-HHMMSS.log`

---

## 2️⃣ monitor-vms-and-ceph.sh - Continuous Monitoring

### Quick Start
```bash
# One-time check
./monitor-vms-and-ceph.sh

# Continuous (every 5 minutes)
./monitor-vms-and-ceph.sh --loop 300

# With Slack alerts
./monitor-vms-and-ceph.sh --loop 300 --webhook https://hooks.slack.com/your-webhook
```

### What It Monitors
- ✅ Paused VMs
- ✅ Ceph cluster health
- ✅ New OSD crashes
- ✅ Blocklist growth
- ✅ OSD status
- ✅ Problem node (ocp-virt4-ceph7) health

### Options

| Option | Description |
|--------|-------------|
| `--loop SECONDS` | Check interval (continuous mode) |
| `--daemon` | Run as daemon (logs to file) |
| `--webhook URL` | Send alerts to Slack/webhook |
| `--email ADDRESS` | Send email alerts (requires mailx) |

### Setup as Systemd Service

```bash
sudo cat > /etc/systemd/system/vm-monitor.service << 'SVC'
[Unit]
Description=OpenShift VM and Ceph Monitor
After=network.target

[Service]
Type=simple
ExecStart=/path/to/monitor-vms-and-ceph.sh --loop 300 --daemon
Restart=always
User=your-user

[Install]
WantedBy=multi-user.target
SVC

sudo systemctl enable vm-monitor
sudo systemctl start vm-monitor
```

---

## 3️⃣ diagnose-node.sh - Node Health Diagnostics

### Quick Start
```bash
./diagnose-node.sh ocp-virt4-ceph7
```

### What It Collects
- Node information and resource allocation
- System logs (journalctl, dmesg)
- Hardware health (SMART, memory, CPU)
- Network statistics and errors
- OSD-specific metrics
- Performance data

### Output
Creates `node-diagnostics-TIMESTAMP/` directory with:
- 30+ diagnostic files
- `SUMMARY.md` with quick findings
- Complete logs and metrics

### Share Results
```bash
tar -czf node-diagnostics.tar.gz node-diagnostics-*/
```

---

## 4️⃣ investigate-incident.sh - Incident Analysis

### Quick Start
```bash
./investigate-incident.sh
```

### What It Analyzes
- OSD crash patterns and timeline
- System logs during incident (2026-01-28 04:00-13:00 UTC)
- Hardware errors
- Network issues
- Ceph cluster events
- Performance metrics

### Output
Creates `incident-investigation-TIMESTAMP/` with:
- Crash analysis and timeline
- System logs from incident
- Hardware/network diagnostics
- `INVESTIGATION-REPORT.md` summary

---

## 🚨 Incident Response Runbook

### When VMs Are Paused

1. **Check scope:**
   ```bash
   oc get vmi --all-namespaces | grep False
   ```

2. **Verify Ceph health:**
   ```bash
   oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph -s
   ```

3. **Run recovery:**
   ```bash
   ./fix-paused-vms.sh
   ```

4. **Verify:**
   ```bash
   oc get vmi --all-namespaces | grep False
   ```

### When OSDs Crash

1. **Check crashes:**
   ```bash
   oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph crash ls
   ```

2. **Investigate:**
   ```bash
   ./investigate-incident.sh
   ```

3. **Diagnose node:**
   ```bash
   ./diagnose-node.sh <node-name>
   ```

4. **Archive crashes:**
   ```bash
   oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph crash archive-all
   ```

---

## 📊 2026-01-28 Incident Summary

**Root Cause:** Single node failure (ocp-virt4-ceph7)
- 21 OSD crashes in 7 hours
- OSD.58 crashed 10 times
- 124 VMs affected cluster-wide

**Issue:** `BlueStore::handle_watch_timeout`

**Likely Causes:**
- Disk I/O issues
- CPU overcommit (226%)
- Hardware failure

See `ROOT-CAUSE-ANALYSIS.md` for complete details.

---

## 🛠️ Troubleshooting

### "No paused VMs found"
✅ Good! Nothing to fix.

### "Ceph cluster health issue"
Check details:
```bash
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph health detail
```

### VMs still paused after recovery
Wait 2-3 minutes. If still paused:
```bash
oc describe vmi <vm-name> -n <namespace>
oc logs -n <namespace> virt-launcher-<vm-name>-xxxxx
```

### Blocklist entries keep returning
This is normal - CSI plugin manages blocklist as part of volume lifecycle.

---

## 📚 Useful Commands

### Check Paused VMs
```bash
oc get vmi --all-namespaces -o json | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Paused" and .status=="True")) | "\(.metadata.namespace)/\(.metadata.name)"'
```

### Ceph Health
```bash
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph -s
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph health detail
```

### OSD Status
```bash
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd tree
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd df
```

### Crashes
```bash
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph crash ls
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph crash info <id>
```

### Blocklist
```bash
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph osd blocklist ls
```

---

## 📄 License

Use freely. No warranty provided.

**Last Updated:** 2026-01-29  
**Version:** 1.0
