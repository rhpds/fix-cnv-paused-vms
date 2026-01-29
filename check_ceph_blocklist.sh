#!/bin/bash
################################################################################
# check_ceph_blocklist.sh
# Icinga/Nagios monitoring plugin for Ceph blocklist entries
#
# Usage: ./check_ceph_blocklist.sh [OPTIONS]
#
# Exit codes:
#   0 - OK
#   1 - WARNING
#   2 - CRITICAL
#   3 - UNKNOWN
#
# Options:
#   -w WARNING   Warning threshold (default: 10)
#   -c CRITICAL  Critical threshold (default: 20)
#   -n NAMESPACE Storage namespace (default: openshift-storage)
################################################################################

set -euo pipefail

# Default thresholds
WARNING_THRESHOLD=10
CRITICAL_THRESHOLD=20
STORAGE_NAMESPACE="openshift-storage"

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
        n) STORAGE_NAMESPACE="$OPTARG" ;;
        h)
            echo "Usage: $0 [-w WARNING] [-c CRITICAL] [-n NAMESPACE]"
            echo "  -w WARNING   Warning threshold (default: 10)"
            echo "  -c CRITICAL  Critical threshold (default: 20)"
            echo "  -n NAMESPACE Storage namespace (default: openshift-storage)"
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

# Check if logged into cluster
if ! oc whoami &> /dev/null; then
    echo "UNKNOWN: Not logged into OpenShift cluster"
    exit $STATE_UNKNOWN
fi

# Get blocklist entries
BLOCKLIST_OUTPUT=$(oc exec -n "$STORAGE_NAMESPACE" deploy/rook-ceph-tools -- ceph osd blocklist ls 2>&1) || {
    echo "UNKNOWN: Unable to query Ceph blocklist - $BLOCKLIST_OUTPUT"
    exit $STATE_UNKNOWN
}

# Count blocklist entries (looking for IP addresses)
BLOCKLIST_COUNT=$(echo "$BLOCKLIST_OUTPUT" | grep -cE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" || echo "0")

# Get sample entries for output (first 3)
SAMPLE_ENTRIES=$(echo "$BLOCKLIST_OUTPUT" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -3 | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')

# Performance data
PERFDATA="blocklist_count=${BLOCKLIST_COUNT};${WARNING_THRESHOLD};${CRITICAL_THRESHOLD};0;"

# Determine status and exit
if [[ $BLOCKLIST_COUNT -ge $CRITICAL_THRESHOLD ]]; then
    echo "CRITICAL: Ceph blocklist has $BLOCKLIST_COUNT entries (threshold: ${CRITICAL_THRESHOLD}) - Sample: $SAMPLE_ENTRIES | $PERFDATA"
    exit $STATE_CRITICAL
elif [[ $BLOCKLIST_COUNT -ge $WARNING_THRESHOLD ]]; then
    echo "WARNING: Ceph blocklist has $BLOCKLIST_COUNT entries (threshold: ${WARNING_THRESHOLD}) - Sample: $SAMPLE_ENTRIES | $PERFDATA"
    exit $STATE_WARNING
else
    if [[ $BLOCKLIST_COUNT -eq 0 ]]; then
        echo "OK: Ceph blocklist is empty | $PERFDATA"
    else
        echo "OK: Ceph blocklist has $BLOCKLIST_COUNT entries (within threshold) | $PERFDATA"
    fi
    exit $STATE_OK
fi
