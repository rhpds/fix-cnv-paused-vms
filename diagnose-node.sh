#!/bin/bash
################################################################################
# diagnose-node.sh
# Deep diagnostic script for investigating node health issues
#
# Usage: ./diagnose-node.sh <node-name>
#
# Example: ./diagnose-node.sh ocp-virt4-ceph7
################################################################################

set -euo pipefail

NODE="${1:-}"
OUTPUT_DIR="./node-diagnostics-$(date +%Y%m%d-%H%M%S)"
STORAGE_NAMESPACE="${STORAGE_NAMESPACE:-openshift-storage}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ -z "$NODE" ]]; then
    echo -e "${RED}Error: Node name required${NC}"
    echo "Usage: $0 <node-name>"
    echo "Example: $0 ocp-virt4-ceph7"
    exit 1
fi

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Node Diagnostic Tool                             ║${NC}"
echo -e "${BLUE}║  Deep dive into node health and issues                   ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Target Node:${NC} $NODE"
echo -e "${GREEN}Output Directory:${NC} $OUTPUT_DIR"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $@" | tee -a "$OUTPUT_DIR/diagnostic.log"
}

log_section() {
    echo "" | tee -a "$OUTPUT_DIR/diagnostic.log"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}" | tee -a "$OUTPUT_DIR/diagnostic.log"
    echo -e "${YELLOW}$@${NC}" | tee -a "$OUTPUT_DIR/diagnostic.log"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}" | tee -a "$OUTPUT_DIR/diagnostic.log"
}

run_command() {
    local description="$1"
    local output_file="$2"
    shift 2
    local command="$@"
    
    log "Running: $description"
    echo "# $description" > "$OUTPUT_DIR/$output_file"
    echo "# Command: $command" >> "$OUTPUT_DIR/$output_file"
    echo "# Timestamp: $(date)" >> "$OUTPUT_DIR/$output_file"
    echo "" >> "$OUTPUT_DIR/$output_file"
    
    if eval "$command" >> "$OUTPUT_DIR/$output_file" 2>&1; then
        log "  ✓ Completed"
    else
        log "  ⚠ Command failed (exit code: $?)"
    fi
}

# 1. Basic Node Information
log_section "1. Basic Node Information"

run_command "Node details" "01-node-info.yaml" \
    "oc get node $NODE -o yaml"

run_command "Node description" "02-node-describe.txt" \
    "oc describe node $NODE"

run_command "Node resource allocation" "03-node-resources.txt" \
    "oc describe node $NODE | grep -A 20 'Allocated resources:'"

run_command "Node conditions" "04-node-conditions.json" \
    "oc get node $NODE -o json | jq '.status.conditions'"

# 2. Node Events and Logs
log_section "2. Node Events and History"

run_command "Recent node events" "05-node-events.txt" \
    "oc get events --all-namespaces --field-selector involvedObject.name=$NODE --sort-by='.lastTimestamp' | tail -100"

run_command "Journalctl - last 24h errors" "06-journalctl-errors.txt" \
    "oc debug node/$NODE -- chroot /host journalctl --since '24 hours ago' --priority=err --no-pager"

run_command "Journalctl - yesterday morning (crash time)" "07-journalctl-crash-time.txt" \
    "oc debug node/$NODE -- chroot /host journalctl --since '2026-01-28 04:00' --until '2026-01-28 13:00' --no-pager | head -1000"

run_command "Kernel messages (dmesg)" "08-dmesg.txt" \
    "oc debug node/$NODE -- chroot /host dmesg -T | tail -1000"

# 3. Hardware Health
log_section "3. Hardware Health Checks"

run_command "Hardware errors in dmesg" "09-hardware-errors.txt" \
    "oc debug node/$NODE -- chroot /host dmesg | grep -iE 'error|fail|hardware|mce|ecc|ata|scsi' | tail -500"

run_command "Memory information" "10-meminfo.txt" \
    "oc debug node/$NODE -- chroot /host cat /proc/meminfo"

run_command "CPU information" "11-cpuinfo.txt" \
    "oc debug node/$NODE -- chroot /host cat /proc/cpuinfo | head -100"

run_command "Block devices" "12-block-devices.txt" \
    "oc debug node/$NODE -- chroot /host lsblk -a"

run_command "Disk usage" "13-disk-usage.txt" \
    "oc debug node/$NODE -- chroot /host df -h"

run_command "SMART disk health (if available)" "14-smart-status.txt" \
    "oc debug node/$NODE -- chroot /host bash -c 'for disk in /dev/sd[a-z]; do echo === \$disk ===; smartctl -H \$disk 2>/dev/null || echo SMART not available; done'"

# 4. Network Health
log_section "4. Network Health"

run_command "Network interfaces" "15-network-interfaces.txt" \
    "oc debug node/$NODE -- chroot /host ip addr show"

run_command "Network statistics" "16-network-stats.txt" \
    "oc debug node/$NODE -- chroot /host ip -s link"

run_command "Network errors" "17-network-errors.txt" \
    "oc debug node/$NODE -- chroot /host bash -c 'for iface in \$(ls /sys/class/net/); do echo === \$iface ===; cat /sys/class/net/\$iface/statistics/*errors 2>/dev/null | grep -v ^0$ || echo No errors; done'"

run_command "Network routing" "18-network-routes.txt" \
    "oc debug node/$NODE -- chroot /host ip route show"

# 5. Ceph/OSD Specific
log_section "5. Ceph OSD Information"

run_command "OSDs on this node" "19-osds-on-node.txt" \
    "oc get pods -n $STORAGE_NAMESPACE -o wide | grep $NODE | grep osd"

run_command "OSD resource usage" "20-osd-resources.txt" \
    "oc get pods -n $STORAGE_NAMESPACE -o wide | grep $NODE | grep osd | awk '{print \$1}' | xargs -I {} oc describe pod -n $STORAGE_NAMESPACE {}"

run_command "OSD pod logs (last 500 lines)" "21-osd-logs.txt" \
    "oc get pods -n $STORAGE_NAMESPACE -o name | grep $NODE | grep osd | head -3 | xargs -I {} oc logs -n $STORAGE_NAMESPACE {} --tail=500"

run_command "Ceph OSD tree for this host" "22-ceph-osd-tree.txt" \
    "oc exec -n $STORAGE_NAMESPACE deploy/rook-ceph-tools -- ceph osd tree | grep -A 15 $NODE"

run_command "OSD performance" "23-osd-performance.json" \
    "oc exec -n $STORAGE_NAMESPACE deploy/rook-ceph-tools -- ceph osd perf"

run_command "Ceph crashes on this node" "24-ceph-crashes.txt" \
    "oc exec -n $STORAGE_NAMESPACE deploy/rook-ceph-tools -- ceph crash ls --format json | jq -r '.[] | select(.utsname_hostname==\"$NODE\")'"

# 6. System Performance
log_section "6. System Performance Metrics"

run_command "Load average" "25-load-average.txt" \
    "oc debug node/$NODE -- chroot /host uptime"

run_command "Process list" "26-processes.txt" \
    "oc debug node/$NODE -- chroot /host ps auxf | head -200"

run_command "Top processes by CPU" "27-top-cpu.txt" \
    "oc debug node/$NODE -- chroot /host ps aux --sort=-pcpu | head -50"

run_command "Top processes by memory" "28-top-memory.txt" \
    "oc debug node/$NODE -- chroot /host ps aux --sort=-rss | head -50"

run_command "IO stats" "29-iostat.txt" \
    "oc debug node/$NODE -- chroot /host iostat -x 1 5 || echo 'iostat not available'"

# 7. Storage Performance
log_section "7. Storage Performance"

run_command "Disk IO statistics" "30-disk-io.txt" \
    "oc debug node/$NODE -- chroot /host cat /proc/diskstats"

run_command "Mount points" "31-mounts.txt" \
    "oc debug node/$NODE -- chroot /host mount"

run_command "Filesystem types" "32-filesystems.txt" \
    "oc debug node/$NODE -- chroot /host cat /proc/mounts"

# 8. Time and Clock
log_section "8. Time Synchronization"

run_command "Current time and NTP status" "33-time-sync.txt" \
    "oc debug node/$NODE -- chroot /host bash -c 'date; timedatectl status 2>/dev/null || echo timedatectl not available; chronyc tracking 2>/dev/null || echo chronyc not available'"

# 9. Generate Summary Report
log_section "9. Generating Summary Report"

log "Analyzing collected data..."

cat > "$OUTPUT_DIR/SUMMARY.md" << 'SUMMARY_EOF'
# Node Diagnostic Summary

## Quick Analysis

### Critical Findings
SUMMARY_EOF

# Check for common issues
if grep -q "OOM" "$OUTPUT_DIR/06-journalctl-errors.txt" 2>/dev/null; then
    echo "- ⚠️ **Out of Memory (OOM) events detected**" >> "$OUTPUT_DIR/SUMMARY.md"
fi

if grep -qi "hardware error\|mce\|ecc" "$OUTPUT_DIR/09-hardware-errors.txt" 2>/dev/null; then
    echo "- ⚠️ **Hardware errors detected in kernel logs**" >> "$OUTPUT_DIR/SUMMARY.md"
fi

if grep -qi "timeout\|i/o error" "$OUTPUT_DIR/08-dmesg.txt" 2>/dev/null; then
    echo "- ⚠️ **I/O timeouts or errors detected**" >> "$OUTPUT_DIR/SUMMARY.md"
fi

if grep -qi "network.*down\|link.*down" "$OUTPUT_DIR/17-network-errors.txt" 2>/dev/null; then
    echo "- ⚠️ **Network link issues detected**" >> "$OUTPUT_DIR/SUMMARY.md"
fi

cat >> "$OUTPUT_DIR/SUMMARY.md" << 'SUMMARY_EOF'

### Files Generated
SUMMARY_EOF

ls -lh "$OUTPUT_DIR" | tail -n +2 >> "$OUTPUT_DIR/SUMMARY.md"

cat >> "$OUTPUT_DIR/SUMMARY.md" << 'SUMMARY_EOF'

## Next Steps

1. Review `SUMMARY.md` (this file) for quick findings
2. Check `01-node-info.yaml` for node configuration
3. Review `06-journalctl-errors.txt` for system errors
4. Check `09-hardware-errors.txt` for hardware issues
5. Review `24-ceph-crashes.txt` for OSD crash history
6. Examine `21-osd-logs.txt` for OSD-specific issues

## Investigation Checklist

- [ ] Review hardware errors
- [ ] Check disk SMART status
- [ ] Verify network interface stability
- [ ] Analyze OSD crash patterns
- [ ] Check CPU/memory pressure
- [ ] Review time synchronization
- [ ] Examine I/O performance

SUMMARY_EOF

log_section "Diagnostic Complete!"

echo ""
echo -e "${GREEN}✓ Diagnostics completed successfully${NC}"
echo -e "${GREEN}✓ Output directory:${NC} $OUTPUT_DIR"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Review $OUTPUT_DIR/SUMMARY.md for quick findings"
echo "  2. Check detailed logs in $OUTPUT_DIR/"
echo "  3. Look for patterns in the crash time logs (07-journalctl-crash-time.txt)"
echo "  4. Review hardware errors (09-hardware-errors.txt)"
echo ""
echo -e "${BLUE}To create a tarball for sharing:${NC}"
echo "  tar -czf ${NODE}-diagnostics.tar.gz $OUTPUT_DIR"
echo ""
