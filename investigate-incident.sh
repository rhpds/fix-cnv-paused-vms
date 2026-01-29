#!/bin/bash
################################################################################
# investigate-incident.sh
# Automated investigation script for the OSD crash incident
#
# This script collects evidence about what happened to ocp-virt4-ceph7
# on 2026-01-28 between 04:59-12:01 UTC
################################################################################

set -euo pipefail

NODE="ocp-virt4-ceph7"
INCIDENT_DATE="2026-01-28"
START_TIME="04:00"
END_TIME="13:00"
STORAGE_NAMESPACE="openshift-storage"
OUTPUT_DIR="./incident-investigation-$(date +%Y%m%d-%H%M%S)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Incident Investigation Tool                      ║${NC}"
echo -e "${BLUE}║  Investigating OSD crashes on ocp-virt4-ceph7            ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Incident Date:${NC} $INCIDENT_DATE"
echo -e "${GREEN}Time Window:${NC} $START_TIME - $END_TIME UTC"
echo -e "${GREEN}Affected Node:${NC} $NODE"
echo -e "${GREEN}Output:${NC} $OUTPUT_DIR"
echo ""

mkdir -p "$OUTPUT_DIR"

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $@" | tee -a "$OUTPUT_DIR/investigation.log"
}

log_section() {
    echo "" | tee -a "$OUTPUT_DIR/investigation.log"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}" | tee -a "$OUTPUT_DIR/investigation.log"
    echo -e "${YELLOW}$@${NC}" | tee -a "$OUTPUT_DIR/investigation.log"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}" | tee -a "$OUTPUT_DIR/investigation.log"
}

# 1. Ceph Crash Analysis
log_section "1. Analyzing Ceph OSD Crashes"

log "Getting all OSD crashes..."
oc exec -n $STORAGE_NAMESPACE deploy/rook-ceph-tools -- ceph crash ls --format json > "$OUTPUT_DIR/all-crashes.json"

log "Filtering crashes on $NODE..."
jq -r ".[] | select(.utsname_hostname==\"$NODE\")" "$OUTPUT_DIR/all-crashes.json" > "$OUTPUT_DIR/node-crashes.json"

log "Creating crash timeline..."
jq -r '.timestamp + " " + .entity_name' "$OUTPUT_DIR/node-crashes.json" | sort > "$OUTPUT_DIR/crash-timeline.txt"

log "Grouping crashes by OSD..."
jq -r 'group_by(.entity_name) | map({osd: .[0].entity_name, count: length, crashes: map(.timestamp)})' "$OUTPUT_DIR/node-crashes.json" > "$OUTPUT_DIR/crashes-by-osd.json"

log "Getting detailed info for worst offender (OSD.58)..."
WORST_CRASH=$(jq -r '.[] | select(.entity_name=="osd.58") | .crash_id' "$OUTPUT_DIR/node-crashes.json" | head -1)
if [[ -n "$WORST_CRASH" ]]; then
    oc exec -n $STORAGE_NAMESPACE deploy/rook-ceph-tools -- ceph crash info "$WORST_CRASH" > "$OUTPUT_DIR/osd58-crash-detail.json"
fi

# 2. OSD Status During Incident
log_section "2. OSD Configuration and Status"

log "Getting current OSD tree for context..."
oc exec -n $STORAGE_NAMESPACE deploy/rook-ceph-tools -- ceph osd tree > "$OUTPUT_DIR/current-osd-tree.txt"

log "Getting OSDs hosted on $NODE..."
oc exec -n $STORAGE_NAMESPACE deploy/rook-ceph-tools -- ceph osd tree --format json | \
    jq -r ".nodes[] | select(.type==\"host\" and .name==\"$NODE\") | .children[]" > "$OUTPUT_DIR/osds-on-node.txt"

log "Getting OSD metadata..."
while read -r osd_id; do
    oc exec -n $STORAGE_NAMESPACE deploy/rook-ceph-tools -- ceph osd metadata "$osd_id" >> "$OUTPUT_DIR/osd-metadata.json" 2>/dev/null || true
done < "$OUTPUT_DIR/osds-on-node.txt"

# 3. Node Logs During Incident
log_section "3. Node Logs During Incident Window"

log "Collecting journalctl logs from incident time..."
oc debug node/$NODE -- chroot /host journalctl \
    --since "$INCIDENT_DATE $START_TIME" \
    --until "$INCIDENT_DATE $END_TIME" \
    --no-pager > "$OUTPUT_DIR/journalctl-incident-window.txt" 2>&1 || \
    log "⚠️  Could not retrieve journalctl (node may have been rebooted)"

log "Extracting errors from incident window..."
grep -iE "error|fail|timeout|warn|critical" "$OUTPUT_DIR/journalctl-incident-window.txt" > "$OUTPUT_DIR/errors-during-incident.txt" 2>/dev/null || \
    echo "No errors found or journalctl unavailable" > "$OUTPUT_DIR/errors-during-incident.txt"

log "Checking for kernel errors..."
oc debug node/$NODE -- chroot /host dmesg -T > "$OUTPUT_DIR/dmesg-full.txt" 2>&1 || \
    log "⚠️  Could not retrieve dmesg"

# 4. Hardware Health
log_section "4. Hardware Health Indicators"

log "Checking for hardware errors..."
oc debug node/$NODE -- chroot /host dmesg | grep -iE "mce|ecc|hardware error|ata error|scsi.*error" > "$OUTPUT_DIR/hardware-errors.txt" 2>&1 || \
    echo "No hardware errors found in dmesg" > "$OUTPUT_DIR/hardware-errors.txt"

log "Checking disk health..."
oc debug node/$NODE -- chroot /host bash -c 'for disk in /dev/sd[a-z]; do echo "=== $disk ==="; smartctl -a $disk 2>/dev/null || echo "SMART not available"; done' > "$OUTPUT_DIR/smart-all.txt" 2>&1 || \
    log "⚠️  SMART data not available"

log "Checking memory info..."
oc debug node/$NODE -- chroot /host cat /proc/meminfo > "$OUTPUT_DIR/meminfo.txt" 2>&1

# 5. Network Analysis
log_section "5. Network Health During Incident"

log "Checking network statistics..."
oc debug node/$NODE -- chroot /host ip -s link > "$OUTPUT_DIR/network-stats.txt" 2>&1

log "Checking for network errors in logs..."
grep -iE "network|link.*down|eth.*error|timeout" "$OUTPUT_DIR/journalctl-incident-window.txt" > "$OUTPUT_DIR/network-errors.txt" 2>/dev/null || \
    echo "No network errors found" > "$OUTPUT_DIR/network-errors.txt"

# 6. Ceph Cluster Events
log_section "6. Ceph Cluster Events During Incident"

log "Checking Ceph health history..."
oc exec -n $STORAGE_NAMESPACE deploy/rook-ceph-tools -- ceph health detail > "$OUTPUT_DIR/current-health.txt"

log "Getting Ceph mon logs from incident time..."
oc logs -n $STORAGE_NAMESPACE -l app=rook-ceph-mon --since-time="${INCIDENT_DATE}T${START_TIME}:00Z" --limit-bytes=5000000 > "$OUTPUT_DIR/mon-logs-incident.txt" 2>&1 || \
    log "⚠️  Could not retrieve mon logs"

log "Checking for slow ops in incident window..."
grep -i "slow\|timeout" "$OUTPUT_DIR/mon-logs-incident.txt" > "$OUTPUT_DIR/slow-ops.txt" 2>/dev/null || \
    echo "No slow ops found" > "$OUTPUT_DIR/slow-ops.txt"

# 7. Performance Metrics
log_section "7. Performance Analysis"

log "Getting OSD performance stats..."
oc exec -n $STORAGE_NAMESPACE deploy/rook-ceph-tools -- ceph osd perf > "$OUTPUT_DIR/osd-perf.txt"

log "Getting OSD usage..."
oc exec -n $STORAGE_NAMESPACE deploy/rook-ceph-tools -- ceph osd df > "$OUTPUT_DIR/osd-df.txt"

log "Checking OSD process CPU/memory usage..."
for osd in $(cat "$OUTPUT_DIR/osds-on-node.txt"); do
    POD=$(oc get pods -n $STORAGE_NAMESPACE -o name | grep "osd-$osd-" | head -1)
    if [[ -n "$POD" ]]; then
        oc top "$POD" -n $STORAGE_NAMESPACE >> "$OUTPUT_DIR/osd-resource-usage.txt" 2>&1 || true
    fi
done

# 8. OSD Pod Events
log_section "8. OSD Pod Events and Restarts"

log "Checking OSD pod events..."
for osd in $(cat "$OUTPUT_DIR/osds-on-node.txt"); do
    POD=$(oc get pods -n $STORAGE_NAMESPACE -o name | grep "osd-$osd-" | head -1 | sed 's|pod/||')
    if [[ -n "$POD" ]]; then
        echo "=== Events for OSD.$osd ($POD) ===" >> "$OUTPUT_DIR/osd-pod-events.txt"
        oc get events -n $STORAGE_NAMESPACE --field-selector involvedObject.name="$POD" --sort-by='.lastTimestamp' >> "$OUTPUT_DIR/osd-pod-events.txt" 2>&1 || true
        echo "" >> "$OUTPUT_DIR/osd-pod-events.txt"
    fi
done

log "Checking OSD pod restart counts..."
for osd in $(cat "$OUTPUT_DIR/osds-on-node.txt"); do
    POD=$(oc get pods -n $STORAGE_NAMESPACE | grep "osd-$osd-" | head -1 | awk '{print $1}')
    if [[ -n "$POD" ]]; then
        RESTARTS=$(oc get pod "$POD" -n $STORAGE_NAMESPACE -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "N/A")
        echo "OSD.$osd: $RESTARTS restarts" >> "$OUTPUT_DIR/osd-restarts.txt"
    fi
done

# 9. Generate Investigation Report
log_section "9. Generating Investigation Report"

cat > "$OUTPUT_DIR/INVESTIGATION-REPORT.md" << 'REPORT_EOF'
# Incident Investigation Report
## OSD Crashes on ocp-virt4-ceph7

**Incident Date:** 2026-01-28  
**Time Window:** 04:00 - 13:00 UTC  
**Affected Node:** ocp-virt4-ceph7  
**Generated:** $(date)

---

## Executive Summary

This report contains automated analysis of the OSD crash incident.

REPORT_EOF

# Count crashes
CRASH_COUNT=$(jq length "$OUTPUT_DIR/node-crashes.json")
echo "**Total Crashes on Node:** $CRASH_COUNT" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
echo "" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"

# List affected OSDs
echo "### Affected OSDs" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
echo '```' >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
jq -r '.[].entity_name' "$OUTPUT_DIR/node-crashes.json" | sort | uniq -c >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
echo '```' >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
echo "" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"

# Crash timeline
echo "### Crash Timeline" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
echo '```' >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
head -20 "$OUTPUT_DIR/crash-timeline.txt" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
echo '```' >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
echo "" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"

# Key findings
echo "### Key Findings" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
echo "" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"

if grep -qi "hardware error\|mce\|ecc" "$OUTPUT_DIR/hardware-errors.txt"; then
    echo "- ⚠️ **Hardware errors detected** - See hardware-errors.txt" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
fi

if grep -qi "oom\|out of memory" "$OUTPUT_DIR/errors-during-incident.txt"; then
    echo "- ⚠️ **Out of memory events detected** - See errors-during-incident.txt" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
fi

if grep -qi "timeout\|slow.*request" "$OUTPUT_DIR/slow-ops.txt"; then
    echo "- ⚠️ **Slow operations detected** - See slow-ops.txt" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
fi

if grep -qi "network\|link.*down" "$OUTPUT_DIR/network-errors.txt"; then
    echo "- ⚠️ **Network issues detected** - See network-errors.txt" >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md"
fi

# Files generated
cat >> "$OUTPUT_DIR/INVESTIGATION-REPORT.md" << 'REPORT_EOF'

---

## Files Generated

| File | Description |
|------|-------------|
| `INVESTIGATION-REPORT.md` | This summary report |
| `crash-timeline.txt` | Chronological list of all crashes |
| `crashes-by-osd.json` | Crashes grouped by OSD ID |
| `osd58-crash-detail.json` | Detailed crash info for worst offender |
| `journalctl-incident-window.txt` | Full system logs during incident |
| `errors-during-incident.txt` | Filtered errors from system logs |
| `hardware-errors.txt` | Hardware-related errors from kernel |
| `smart-all.txt` | SMART disk health data |
| `network-errors.txt` | Network-related errors |
| `slow-ops.txt` | Slow Ceph operations |
| `osd-pod-events.txt` | Kubernetes events for OSD pods |
| `osd-restarts.txt` | OSD container restart counts |

---

## Next Steps

1. **Review hardware-errors.txt** for physical issues
2. **Check errors-during-incident.txt** for system-level problems
3. **Analyze crash-timeline.txt** for patterns
4. **Review slow-ops.txt** for performance issues
5. **Check smart-all.txt** for disk health

## Investigation Checklist

- [ ] Hardware errors identified
- [ ] Disk health verified
- [ ] Network stability confirmed
- [ ] Memory pressure checked
- [ ] OSD crash pattern analyzed
- [ ] Root cause hypothesis formed

REPORT_EOF

log_section "Investigation Complete!"

echo ""
echo -e "${GREEN}✓ Investigation completed${NC}"
echo -e "${GREEN}✓ Output directory:${NC} $OUTPUT_DIR"
echo ""
echo -e "${YELLOW}Quick Analysis:${NC}"
echo "  Total crashes: $CRASH_COUNT"
echo "  Crash timeline: $OUTPUT_DIR/crash-timeline.txt"
echo "  Full report: $OUTPUT_DIR/INVESTIGATION-REPORT.md"
echo ""
echo -e "${BLUE}To review findings:${NC}"
echo "  cat $OUTPUT_DIR/INVESTIGATION-REPORT.md"
echo ""
echo -e "${BLUE}To share with team:${NC}"
echo "  tar -czf incident-investigation.tar.gz $OUTPUT_DIR"
echo ""
