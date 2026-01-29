#!/bin/bash
################################################################################
# monitor-vms-and-ceph.sh
# Monitoring script for paused VMs and Ceph health issues
#
# Usage: 
#   ./monitor-vms-and-ceph.sh              # Run once
#   ./monitor-vms-and-ceph.sh --loop 300   # Run every 5 minutes
#   ./monitor-vms-and-ceph.sh --daemon     # Run as systemd service
#
# Options:
#   --loop SECONDS     Run continuously with specified interval
#   --daemon           Run as daemon (logs to file)
#   --webhook URL      Send alerts to webhook URL
#   --email ADDRESS    Send alerts to email (requires mailx)
################################################################################

set -euo pipefail

# Configuration
STORAGE_NAMESPACE="${STORAGE_NAMESPACE:-openshift-storage}"
CHECK_INTERVAL=300  # 5 minutes default
WEBHOOK_URL="${WEBHOOK_URL:-}"
EMAIL_ADDRESS="${EMAIL_ADDRESS:-}"
LOG_FILE="/var/log/vm-ceph-monitor.log"
STATE_FILE="/tmp/vm-ceph-monitor.state"
DAEMON_MODE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --loop)
            CHECK_INTERVAL="$2"
            shift 2
            ;;
        --daemon)
            DAEMON_MODE=true
            shift
            ;;
        --webhook)
            WEBHOOK_URL="$2"
            shift 2
            ;;
        --email)
            EMAIL_ADDRESS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Logging
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ "$DAEMON_MODE" == true ]]; then
        echo "${timestamp} [${level}] ${message}" >> "$LOG_FILE"
    else
        echo -e "${timestamp} [${level}] ${message}"
    fi
}

# Send alert via webhook
send_webhook_alert() {
    local title="$1"
    local message="$2"
    local severity="$3"  # info, warning, critical
    
    if [[ -z "$WEBHOOK_URL" ]]; then
        return
    fi
    
    local color
    case "$severity" in
        critical) color="danger" ;;
        warning) color="warning" ;;
        *) color="good" ;;
    esac
    
    local payload=$(cat <<-END
{
  "text": "${title}",
  "attachments": [{
    "color": "${color}",
    "text": "${message}",
    "footer": "OpenShift VM Monitor",
    "ts": $(date +%s)
  }]
}
END
)
    
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$WEBHOOK_URL" > /dev/null 2>&1
}

# Send email alert
send_email_alert() {
    local subject="$1"
    local message="$2"
    
    if [[ -z "$EMAIL_ADDRESS" ]]; then
        return
    fi
    
    if command -v mailx &> /dev/null; then
        echo "$message" | mailx -s "$subject" "$EMAIL_ADDRESS"
    fi
}

# Check for paused VMs
check_paused_vms() {
    local paused_vms=$(oc get vmi --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.conditions[]? | select(.type=="Paused" and .status=="True")) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")
    
    local count=$(echo "$paused_vms" | grep -c "/" || echo "0")
    
    if [[ $count -gt 0 ]]; then
        log "CRITICAL" "Found $count paused VMs!"
        echo "$paused_vms" | while read -r vm; do
            log "CRITICAL" "  - $vm"
        done
        
        # Check if this is a new alert
        if ! grep -q "PAUSED_VMS:$count" "$STATE_FILE" 2>/dev/null; then
            send_webhook_alert "⚠️ VMs Paused Alert" "$count VMs are currently paused:\n$paused_vms" "critical"
            send_email_alert "CRITICAL: $count VMs Paused" "$paused_vms"
            echo "PAUSED_VMS:$count" >> "$STATE_FILE"
        fi
        
        return 1
    else
        log "INFO" "No paused VMs found ✓"
        # Clear state if VMs recovered
        sed -i '/PAUSED_VMS:/d' "$STATE_FILE" 2>/dev/null || true
        return 0
    fi
}

# Check Ceph health
check_ceph_health() {
    local health=$(oc exec -n "$STORAGE_NAMESPACE" deploy/rook-ceph-tools -- ceph health 2>/dev/null || echo "UNKNOWN")
    
    case "$health" in
        HEALTH_OK)
            log "INFO" "Ceph health: $health ✓"
            sed -i '/CEPH_HEALTH:/d' "$STATE_FILE" 2>/dev/null || true
            return 0
            ;;
        HEALTH_WARN)
            log "WARNING" "Ceph health: $health"
            local details=$(oc exec -n "$STORAGE_NAMESPACE" deploy/rook-ceph-tools -- ceph health detail 2>/dev/null)
            log "WARNING" "$details"
            
            if ! grep -q "CEPH_HEALTH:WARN" "$STATE_FILE" 2>/dev/null; then
                send_webhook_alert "⚠️ Ceph Health Warning" "Ceph cluster has warnings:\n$details" "warning"
                send_email_alert "WARNING: Ceph Health WARN" "$details"
                echo "CEPH_HEALTH:WARN" >> "$STATE_FILE"
            fi
            return 1
            ;;
        *)
            log "CRITICAL" "Ceph health: $health"
            local details=$(oc exec -n "$STORAGE_NAMESPACE" deploy/rook-ceph-tools -- ceph health detail 2>/dev/null || echo "Unable to get details")
            log "CRITICAL" "$details"
            
            if ! grep -q "CEPH_HEALTH:ERROR" "$STATE_FILE" 2>/dev/null; then
                send_webhook_alert "🚨 Ceph Health Critical" "Ceph cluster is unhealthy:\n$details" "critical"
                send_email_alert "CRITICAL: Ceph Health Error" "$details"
                echo "CEPH_HEALTH:ERROR" >> "$STATE_FILE"
            fi
            return 1
            ;;
    esac
}

# Check for new OSD crashes
check_osd_crashes() {
    local crash_count=$(oc exec -n "$STORAGE_NAMESPACE" deploy/rook-ceph-tools -- ceph crash ls 2>/dev/null | grep -c "^20" || echo "0")
    
    # Get last known crash count
    local last_count=$(grep "OSD_CRASHES:" "$STATE_FILE" 2>/dev/null | cut -d: -f2 || echo "0")
    
    if [[ $crash_count -gt 0 ]]; then
        if [[ $crash_count -gt $last_count ]]; then
            local new_crashes=$((crash_count - last_count))
            log "CRITICAL" "Detected $new_crashes new OSD crashes (total: $crash_count)"
            
            # Get recent crashes
            local recent_crashes=$(oc exec -n "$STORAGE_NAMESPACE" deploy/rook-ceph-tools -- ceph crash ls 2>/dev/null | head -10)
            log "CRITICAL" "$recent_crashes"
            
            send_webhook_alert "🚨 New OSD Crashes" "$new_crashes new OSD crashes detected (total: $crash_count)" "critical"
            send_email_alert "CRITICAL: New OSD Crashes" "$recent_crashes"
        fi
        
        # Update state
        sed -i '/OSD_CRASHES:/d' "$STATE_FILE" 2>/dev/null || true
        echo "OSD_CRASHES:$crash_count" >> "$STATE_FILE"
        return 1
    else
        log "INFO" "No OSD crashes found ✓"
        return 0
    fi
}

# Check blocklist
check_blocklist() {
    local blocklist_count=$(oc exec -n "$STORAGE_NAMESPACE" deploy/rook-ceph-tools -- ceph osd blocklist ls 2>/dev/null | grep -c "^10\." || echo "0")
    
    if [[ $blocklist_count -gt 10 ]]; then
        log "WARNING" "Found $blocklist_count entries in Ceph blocklist"
        
        if ! grep -q "BLOCKLIST:$blocklist_count" "$STATE_FILE" 2>/dev/null; then
            send_webhook_alert "⚠️ High Blocklist Count" "$blocklist_count entries in Ceph blocklist" "warning"
            send_email_alert "WARNING: High Blocklist Count" "Blocklist has $blocklist_count entries"
            echo "BLOCKLIST:$blocklist_count" >> "$STATE_FILE"
        fi
        return 1
    else
        log "INFO" "Blocklist count: $blocklist_count ✓"
        sed -i '/BLOCKLIST:/d' "$STATE_FILE" 2>/dev/null || true
        return 0
    fi
}

# Check OSD status
check_osd_status() {
    local osd_status=$(oc exec -n "$STORAGE_NAMESPACE" deploy/rook-ceph-tools -- ceph osd stat 2>/dev/null || echo "")
    
    if echo "$osd_status" | grep -q "70 up"; then
        log "INFO" "OSD status: $osd_status ✓"
        return 0
    else
        log "WARNING" "OSD status: $osd_status"
        
        if ! grep -q "OSD_DOWN" "$STATE_FILE" 2>/dev/null; then
            send_webhook_alert "⚠️ OSD Status Issue" "OSD status: $osd_status" "warning"
            send_email_alert "WARNING: OSD Status" "$osd_status"
            echo "OSD_DOWN" >> "$STATE_FILE"
        fi
        return 1
    fi
}

# Check specific problematic node
check_problem_node() {
    local node="ocp-virt4-ceph7"
    local node_status=$(oc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    
    if [[ "$node_status" != "True" ]]; then
        log "CRITICAL" "Problem node $node is not Ready: $node_status"
        
        if ! grep -q "NODE_NOT_READY" "$STATE_FILE" 2>/dev/null; then
            send_webhook_alert "🚨 Problem Node Not Ready" "Node $node status: $node_status" "critical"
            send_email_alert "CRITICAL: Problem Node Not Ready" "Node $node is not ready"
            echo "NODE_NOT_READY" >> "$STATE_FILE"
        fi
        return 1
    else
        log "INFO" "Problem node $node is Ready ✓"
        sed -i '/NODE_NOT_READY/d' "$STATE_FILE" 2>/dev/null || true
        return 0
    fi
}

# Main monitoring function
run_checks() {
    log "INFO" "========================================="
    log "INFO" "Starting monitoring checks..."
    log "INFO" "========================================="
    
    local failures=0
    
    check_paused_vms || ((failures++))
    check_ceph_health || ((failures++))
    check_osd_crashes || ((failures++))
    check_blocklist || ((failures++))
    check_osd_status || ((failures++))
    check_problem_node || ((failures++))
    
    log "INFO" "========================================="
    if [[ $failures -eq 0 ]]; then
        log "INFO" "All checks passed! ✓"
    else
        log "WARNING" "$failures checks failed"
    fi
    log "INFO" "========================================="
    
    return $failures
}

# Main execution
main() {
    # Initialize state file
    touch "$STATE_FILE"
    
    if [[ "$DAEMON_MODE" == true ]]; then
        log "INFO" "Starting in daemon mode, logging to $LOG_FILE"
    fi
    
    log "INFO" "VM and Ceph Monitor started"
    log "INFO" "Check interval: ${CHECK_INTERVAL}s"
    
    if [[ "$CHECK_INTERVAL" -gt 0 ]]; then
        while true; do
            run_checks
            log "INFO" "Sleeping for ${CHECK_INTERVAL}s..."
            sleep "$CHECK_INTERVAL"
        done
    else
        run_checks
    fi
}

# Run main
main
