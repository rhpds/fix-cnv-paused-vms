#!/bin/bash
################################################################################
# check_paused_vms.sh
# Icinga/Nagios monitoring plugin for paused VirtualMachineInstances
#
# Usage: ./check_paused_vms.sh [OPTIONS]
#
# Exit codes:
#   0 - OK
#   1 - WARNING
#   2 - CRITICAL
#   3 - UNKNOWN
#
# Options:
#   -w WARNING   Warning threshold (default: 1)
#   -c CRITICAL  Critical threshold (default: 5)
#   -n NAMESPACE Check specific namespace only (default: all namespaces)
################################################################################

set -euo pipefail

# Default thresholds
WARNING_THRESHOLD=1
CRITICAL_THRESHOLD=5
NAMESPACE=""

# Nagios exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# Parse arguments
while getopts "w:c:n:h" opt; do
    case $opt in
        w) WARNING_THRESHOLD="$OPTARG" ;;
        c) CRITICAL_THRESHOLD="$OPTARG" ;;
        n) NAMESPACE="$OPTARG" ;;
        h)
            echo "Usage: $0 [-w WARNING] [-c CRITICAL] [-n NAMESPACE]"
            echo "  -w WARNING   Warning threshold (default: 1)"
            echo "  -c CRITICAL  Critical threshold (default: 5)"
            echo "  -n NAMESPACE Check specific namespace only (default: all)"
            exit $STATE_OK
            ;;
        *)
            echo "UNKNOWN: Invalid option"
            exit $STATE_UNKNOWN
            ;;
    esac
done

# Validate thresholds
if [[ $WARNING_THRESHOLD -ge $CRITICAL_THRESHOLD ]]; then
    echo "UNKNOWN: Warning threshold must be less than critical threshold"
    exit $STATE_UNKNOWN
fi

# Check if oc is available
if ! command -v oc &> /dev/null; then
    echo "UNKNOWN: oc command not found"
    exit $STATE_UNKNOWN
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "UNKNOWN: jq command not found"
    exit $STATE_UNKNOWN
fi

# Check if logged into cluster
if ! oc whoami &> /dev/null; then
    echo "UNKNOWN: Not logged into OpenShift cluster"
    exit $STATE_UNKNOWN
fi

# Build namespace flag
NAMESPACE_FLAG="--all-namespaces"
if [[ -n "$NAMESPACE" ]]; then
    NAMESPACE_FLAG="-n $NAMESPACE"
fi

# Get paused VMs
PAUSED_VMS_OUTPUT=$(oc get vmi $NAMESPACE_FLAG -o json 2>&1) || {
    echo "UNKNOWN: Unable to query VirtualMachineInstances - $PAUSED_VMS_OUTPUT"
    exit $STATE_UNKNOWN
}

# Parse paused VMs
PAUSED_VMS=$(echo "$PAUSED_VMS_OUTPUT" | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Paused" and .status=="True")) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")

# Count paused VMs
if [[ -z "$PAUSED_VMS" ]]; then
    PAUSED_COUNT=0
    VM_LIST=""
else
    PAUSED_COUNT=$(echo "$PAUSED_VMS" | wc -l | tr -d ' ')
    # Get first 5 for display
    VM_LIST=$(echo "$PAUSED_VMS" | head -5 | tr '\n' ',' | sed 's/,$//')
fi

# Performance data
PERFDATA="paused_vms=${PAUSED_COUNT};${WARNING_THRESHOLD};${CRITICAL_THRESHOLD};0;"

# Determine status and exit
if [[ $PAUSED_COUNT -ge $CRITICAL_THRESHOLD ]]; then
    echo "CRITICAL: $PAUSED_COUNT VMs are paused (threshold: ${CRITICAL_THRESHOLD}) - VMs: $VM_LIST | $PERFDATA"
    exit $STATE_CRITICAL
elif [[ $PAUSED_COUNT -ge $WARNING_THRESHOLD ]]; then
    echo "WARNING: $PAUSED_COUNT VMs are paused (threshold: ${WARNING_THRESHOLD}) - VMs: $VM_LIST | $PERFDATA"
    exit $STATE_WARNING
else
    if [[ -n "$NAMESPACE" ]]; then
        echo "OK: No paused VMs in namespace $NAMESPACE | $PERFDATA"
    else
        echo "OK: No paused VMs found cluster-wide | $PERFDATA"
    fi
    exit $STATE_OK
fi
