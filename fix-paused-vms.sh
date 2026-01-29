#!/bin/bash
################################################################################
# fix-paused-vms.sh
# Portable script to recover VMs paused due to Ceph blocklist issues
#
# Usage: ./fix-paused-vms.sh [OPTIONS]
#
# Options:
#   -b, --batch-size NUM       Number of VMs to restart per batch (default: 10)
#   -d, --delay SECONDS        Delay between batches in seconds (default: 60)
#   -n, --namespace NAME       Only fix VMs in specific namespace (default: all)
#   -s, --storage-namespace NS Ceph storage namespace (default: openshift-storage)
#   -y, --yes                  Skip confirmation prompts
#   -h, --help                 Show this help message
#
# Example:
#   ./fix-paused-vms.sh -b 20 -d 30        # 20 VMs per batch, 30s delay
#   ./fix-paused-vms.sh -n my-namespace    # Only fix VMs in my-namespace
################################################################################

set -euo pipefail

# Default configuration
BATCH_SIZE=10
DELAY_BETWEEN_BATCHES=60
TARGET_NAMESPACE="--all-namespaces"
STORAGE_NAMESPACE="openshift-storage"
SKIP_CONFIRMATION=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/vm-recovery-$(date +%Y%m%d-%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -b|--batch-size)
                BATCH_SIZE="$2"
                shift 2
                ;;
            -d|--delay)
                DELAY_BETWEEN_BATCHES="$2"
                shift 2
                ;;
            -n|--namespace)
                TARGET_NAMESPACE="-n $2"
                shift 2
                ;;
            -s|--storage-namespace)
                STORAGE_NAMESPACE="$2"
                shift 2
                ;;
            -y|--yes)
                SKIP_CONFIRMATION=true
                shift
                ;;
            -h|--help)
                grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# //' | sed 's/^#//'
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                exit 1
                ;;
        esac
    done
}

# Logging function
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() {
    log "INFO" "${BLUE}$@${NC}"
}

log_success() {
    log "SUCCESS" "${GREEN}$@${NC}"
}

log_warning() {
    log "WARNING" "${YELLOW}$@${NC}"
}

log_error() {
    log "ERROR" "${RED}$@${NC}"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v oc &> /dev/null; then
        log_error "oc CLI not found. Please install OpenShift CLI."
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Please install jq."
        exit 1
    fi
    
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Run 'oc login' first."
        exit 1
    fi
    
    if ! oc get namespace "$STORAGE_NAMESPACE" &> /dev/null; then
        log_error "Storage namespace '$STORAGE_NAMESPACE' not found."
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Get Ceph cluster status
check_ceph_health() {
    log_info "Checking Ceph cluster health..."
    
    local health=$(oc exec -n "$STORAGE_NAMESPACE" deploy/rook-ceph-tools -- ceph health 2>/dev/null || echo "UNKNOWN")
    
    if [[ "$health" == "HEALTH_OK" ]]; then
        log_success "Ceph cluster is healthy: $health"
    elif [[ "$health" == "HEALTH_WARN" ]]; then
        log_warning "Ceph cluster has warnings: $health"
    else
        log_error "Ceph cluster health issue: $health"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Clear Ceph blocklist
clear_blocklist() {
    log_info "Checking Ceph blocklist..."
    
    local blocklist_count=$(oc exec -n "$STORAGE_NAMESPACE" deploy/rook-ceph-tools -- ceph osd blocklist ls 2>/dev/null | grep -c "^10\." || echo "0")
    
    if [[ "$blocklist_count" -eq 0 ]]; then
        log_info "No blocklist entries found"
        return
    fi
    
    log_warning "Found $blocklist_count blocklist entries"
    
    if [[ "$SKIP_CONFIRMATION" == false ]]; then
        read -p "Clear all blocklist entries? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping blocklist clearing"
            return
        fi
    fi
    
    log_info "Clearing blocklist entries..."
    
    oc exec -n "$STORAGE_NAMESPACE" deploy/rook-ceph-tools -- ceph osd blocklist ls 2>/dev/null | \
        grep "^10\." | \
        awk '{print $1}' | \
        while read -r entry; do
            log_info "  Removing: $entry"
            oc exec -n "$STORAGE_NAMESPACE" deploy/rook-ceph-tools -- ceph osd blocklist rm "$entry" 2>&1 | tee -a "$LOG_FILE"
        done
    
    log_success "Blocklist cleared"
}

# Find paused VMs
find_paused_vms() {
    log_info "Finding paused VMs..."
    
    local paused_vms=$(oc get vmi $TARGET_NAMESPACE -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.conditions[]? | select(.type=="Paused" and .status=="True")) | "\(.metadata.namespace) \(.metadata.name)"')
    
    if [[ -z "$paused_vms" ]]; then
        log_success "No paused VMs found!"
        return 1
    fi
    
    echo "$paused_vms" > /tmp/paused_vms_list.txt
    local count=$(wc -l < /tmp/paused_vms_list.txt)
    
    log_warning "Found $count paused VMs"
    
    echo "$paused_vms" | head -10 | while read -r line; do
        log_info "  - $line"
    done
    
    if [[ $count -gt 10 ]]; then
        log_info "  ... and $((count - 10)) more"
    fi
    
    return 0
}

# Restart paused VMs in batches
restart_vms() {
    local total=$(wc -l < /tmp/paused_vms_list.txt)
    local batches=$(( (total + BATCH_SIZE - 1) / BATCH_SIZE ))
    
    log_info "Will restart $total VMs in $batches batches"
    log_info "Batch size: $BATCH_SIZE, Delay between batches: ${DELAY_BETWEEN_BATCHES}s"
    
    if [[ "$SKIP_CONFIRMATION" == false ]]; then
        read -p "Proceed with VM restarts? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Operation cancelled"
            exit 0
        fi
    fi
    
    local count=0
    local batch_num=0
    local batch_count=0
    local failed=0
    
    while IFS= read -r line; do
        local namespace=$(echo "$line" | awk '{print $1}')
        local vmname=$(echo "$line" | awk '{print $2}')
        count=$((count+1))
        batch_count=$((batch_count+1))
        
        if [[ $batch_count -eq 1 ]]; then
            batch_num=$((batch_num+1))
            log_info "=== BATCH $batch_num/$batches ==="
        fi
        
        log_info "[$count/$total] Restarting: $namespace/$vmname"
        
        local pod=$(oc get pods -n "$namespace" -o name 2>/dev/null | grep "virt-launcher-$vmname-" | head -1)
        
        if [[ -n "$pod" ]]; then
            if oc delete "$pod" -n "$namespace" --wait=false 2>/dev/null; then
                log_success "  ✓ Deleted $pod"
            else
                log_error "  ✗ Failed to delete pod"
                ((failed++))
            fi
        else
            log_warning "  ⚠ Pod not found"
            ((failed++))
        fi
        
        # After each batch, pause
        if [[ $batch_count -eq $BATCH_SIZE ]] || [[ $count -eq $total ]]; then
            batch_count=0
            if [[ $count -lt $total ]]; then
                log_info "Batch $batch_num complete. Waiting ${DELAY_BETWEEN_BATCHES}s..."
                sleep "$DELAY_BETWEEN_BATCHES"
            fi
        fi
    done < /tmp/paused_vms_list.txt
    
    log_success "=== COMPLETED ==="
    log_success "Restarted $((count - failed))/$count VMs successfully"
    
    if [[ $failed -gt 0 ]]; then
        log_warning "$failed VMs failed to restart"
    fi
}

# Verify recovery
verify_recovery() {
    log_info "Waiting 60s for VMs to stabilize..."
    sleep 60
    
    log_info "Checking for remaining paused VMs..."
    
    local still_paused=$(oc get vmi $TARGET_NAMESPACE -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.conditions[]? | select(.type=="Paused" and .status=="True")) | "\(.metadata.namespace)/\(.metadata.name)"' | \
        wc -l)
    
    if [[ "$still_paused" -eq 0 ]]; then
        log_success "All VMs recovered successfully! ✓"
    else
        log_warning "$still_paused VMs still paused. They may need more time or manual intervention."
    fi
}

# Main execution
main() {
    parse_args "$@"
    
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║         OpenShift VM Recovery Tool                       ║"
    echo "║  Fixes VMs paused due to Ceph blocklist issues           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    log_info "Log file: $LOG_FILE"
    log_info "Configuration: batch_size=$BATCH_SIZE, delay=${DELAY_BETWEEN_BATCHES}s"
    
    check_prerequisites
    check_ceph_health
    clear_blocklist
    
    if find_paused_vms; then
        restart_vms
        verify_recovery
    fi
    
    log_success "Recovery process complete!"
    log_info "Full log available at: $LOG_FILE"
}

# Run main function
main "$@"
