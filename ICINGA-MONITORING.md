# Icinga/Nagios Monitoring Integration

This guide explains how to integrate the OpenShift CNV monitoring checks into Icinga or Nagios.

---

## Scripts Included

| Script | Purpose | Default Thresholds |
|--------|---------|-------------------|
| `check_paused_vms.sh` | Monitor paused VirtualMachineInstances | WARN: 1, CRIT: 5 |
| `check_ceph_blocklist.sh` | Monitor Ceph blocklist entries | WARN: 10, CRIT: 20 |

---

## Quick Test

```bash
# Test paused VMs check
./check_paused_vms.sh
# Expected: OK: No paused VMs found cluster-wide | paused_vms=0;1;5;0;

# Test blocklist check
./check_ceph_blocklist.sh
# Expected: OK: Ceph blocklist has X entries (within threshold) | blocklist_count=X;10;20;0;

# Test with custom thresholds
./check_paused_vms.sh -w 2 -c 10
./check_ceph_blocklist.sh -w 15 -c 30

# Test specific namespace
./check_paused_vms.sh -n sandbox-jsdhh-ocp4-cluster
```

---

## Installation on Icinga Server

### 1. Copy Scripts to Icinga Plugin Directory

```bash
# Copy to standard Nagios plugin location
sudo cp check_paused_vms.sh /usr/lib64/nagios/plugins/
sudo cp check_ceph_blocklist.sh /usr/lib64/nagios/plugins/

# Set ownership and permissions
sudo chown nagios:nagios /usr/lib64/nagios/plugins/check_*.sh
sudo chmod 755 /usr/lib64/nagios/plugins/check_*.sh
```

### 2. Configure OpenShift Access

The scripts need `oc` CLI access to your cluster. Set up authentication:

**Option A: Service Account Token (Recommended)**

```bash
# On OpenShift cluster, create monitoring service account
oc create serviceaccount icinga-monitor -n openshift-storage

# Grant cluster-reader permissions
oc adm policy add-cluster-role-to-user cluster-reader -z icinga-monitor -n openshift-storage

# Get service account token
TOKEN=$(oc create token icinga-monitor -n openshift-storage --duration=87600h)

# On Icinga server, configure oc to use token
sudo -u nagios oc login https://your-cluster-api:6443 --token="$TOKEN"

# Verify access
sudo -u nagios oc get nodes
```

**Option B: Kubeconfig File**

```bash
# Copy kubeconfig to Icinga server
sudo mkdir -p /var/lib/nagios/.kube
sudo cp ~/.kube/config /var/lib/nagios/.kube/config
sudo chown -R nagios:nagios /var/lib/nagios/.kube
sudo chmod 600 /var/lib/nagios/.kube/config

# Verify access
sudo -u nagios oc get nodes
```

---

## Icinga Configuration

### Define Commands

Add to `/etc/icinga2/conf.d/commands.conf`:

```icinga2
// Check for paused VMs
object CheckCommand "check_paused_vms" {
  command = [ PluginDir + "/check_paused_vms.sh" ]

  arguments = {
    "-w" = {
      value = "$paused_vms_warning$"
      description = "Warning threshold"
    }
    "-c" = {
      value = "$paused_vms_critical$"
      description = "Critical threshold"
    }
    "-n" = {
      value = "$paused_vms_namespace$"
      description = "Namespace to check"
    }
  }
}

// Check Ceph blocklist
object CheckCommand "check_ceph_blocklist" {
  command = [ PluginDir + "/check_ceph_blocklist.sh" ]

  arguments = {
    "-w" = {
      value = "$blocklist_warning$"
      description = "Warning threshold"
    }
    "-c" = {
      value = "$blocklist_critical$"
      description = "Critical threshold"
    }
    "-n" = {
      value = "$blocklist_namespace$"
      description = "Storage namespace"
    }
  }
}
```

### Define Services

Add to `/etc/icinga2/conf.d/services.conf`:

```icinga2
// Monitor paused VMs cluster-wide
apply Service "openshift-paused-vms" {
  import "generic-service"
  check_command = "check_paused_vms"

  vars.paused_vms_warning = 1
  vars.paused_vms_critical = 5

  check_interval = 5m
  retry_interval = 1m
  max_check_attempts = 3

  assign where host.name == "openshift-cluster"
}

// Monitor Ceph blocklist
apply Service "ceph-blocklist" {
  import "generic-service"
  check_command = "check_ceph_blocklist"

  vars.blocklist_warning = 10
  vars.blocklist_critical = 20
  vars.blocklist_namespace = "openshift-storage"

  check_interval = 5m
  retry_interval = 1m
  max_check_attempts = 3

  assign where host.name == "openshift-cluster"
}
```

### Define Host

Add to `/etc/icinga2/conf.d/hosts.conf`:

```icinga2
object Host "openshift-cluster" {
  import "generic-host"
  address = "your-cluster-api.example.com"
  check_command = "hostalive"

  vars.notification["mail"] = {
    groups = [ "openshift-admins" ]
  }
}
```

### Reload Icinga

```bash
# Validate configuration
sudo icinga2 daemon -C

# Reload Icinga
sudo systemctl reload icinga2
```

---

## Nagios Configuration

### Define Commands

Add to `/etc/nagios/objects/commands.cfg`:

```nagios
# Check paused VMs
define command {
    command_name    check_paused_vms
    command_line    $USER1$/check_paused_vms.sh -w $ARG1$ -c $ARG2$
}

# Check Ceph blocklist
define command {
    command_name    check_ceph_blocklist
    command_line    $USER1$/check_ceph_blocklist.sh -w $ARG1$ -c $ARG2$ -n $ARG3$
}
```

### Define Services

Add to `/etc/nagios/objects/services.cfg`:

```nagios
# Monitor paused VMs
define service {
    use                     generic-service
    host_name               openshift-cluster
    service_description     Paused VMs
    check_command           check_paused_vms!1!5
    check_interval          5
    retry_interval          1
    notification_interval   30
}

# Monitor Ceph blocklist
define service {
    use                     generic-service
    host_name               openshift-cluster
    service_description     Ceph Blocklist
    check_command           check_ceph_blocklist!10!20!openshift-storage
    check_interval          5
    retry_interval          1
    notification_interval   30
}
```

### Reload Nagios

```bash
# Validate configuration
sudo nagios -v /etc/nagios/nagios.cfg

# Reload Nagios
sudo systemctl reload nagios
```

---

## Script Options Reference

### check_paused_vms.sh

```bash
Usage: ./check_paused_vms.sh [-w WARNING] [-c CRITICAL] [-n NAMESPACE]

Options:
  -w WARNING   Warning threshold (default: 1)
  -c CRITICAL  Critical threshold (default: 5)
  -n NAMESPACE Check specific namespace only (default: all)
  -h           Show help

Examples:
  ./check_paused_vms.sh                    # Default: warn at 1, critical at 5
  ./check_paused_vms.sh -w 2 -c 10         # Custom thresholds
  ./check_paused_vms.sh -n my-namespace    # Check single namespace
```

### check_ceph_blocklist.sh

```bash
Usage: ./check_ceph_blocklist.sh [-w WARNING] [-c CRITICAL] [-n NAMESPACE]

Options:
  -w WARNING   Warning threshold (default: 10)
  -c CRITICAL  Critical threshold (default: 20)
  -n NAMESPACE Storage namespace (default: openshift-storage)
  -h           Show help

Examples:
  ./check_ceph_blocklist.sh                # Default: warn at 10, critical at 20
  ./check_ceph_blocklist.sh -w 15 -c 30    # Custom thresholds
  ./check_ceph_blocklist.sh -n rook-ceph   # Custom namespace
```

---

## Output Format

Both scripts follow Nagios plugin API:

**Status Line:**
```
STATUS: message | performance_data
```

**Exit Codes:**
- `0` = OK - Everything is normal
- `1` = WARNING - Threshold exceeded (warning level)
- `2` = CRITICAL - Threshold exceeded (critical level)
- `3` = UNKNOWN - Script error or cluster unreachable

**Performance Data:**
- `paused_vms=X;W;C;0;` - Number of paused VMs
- `blocklist_count=X;W;C;0;` - Number of blocklist entries

---

## Example Outputs

### Paused VMs Check

```bash
# No paused VMs (OK)
OK: No paused VMs found cluster-wide | paused_vms=0;1;5;0;

# 2 VMs paused (WARNING with default threshold of 1)
WARNING: 2 VMs are paused (threshold: 1) - VMs: namespace1/vm1,namespace2/vm2 | paused_vms=2;1;5;0;

# 10 VMs paused (CRITICAL with default threshold of 5)
CRITICAL: 10 VMs are paused (threshold: 5) - VMs: ns1/vm1,ns1/vm2,ns2/vm3,ns3/vm4,ns4/vm5 | paused_vms=10;1;5;0;
```

### Blocklist Check

```bash
# Few entries (OK)
OK: Ceph blocklist has 3 entries (within threshold) | blocklist_count=3;10;20;0;

# 12 entries (WARNING with default threshold of 10)
WARNING: Ceph blocklist has 12 entries (threshold: 10) - Sample: 10.190.105.11:0/123,10.190.105.35:0/456,10.190.105.42:0/789 | blocklist_count=12;10;20;0;

# 25 entries (CRITICAL with default threshold of 20)
CRITICAL: Ceph blocklist has 25 entries (threshold: 20) - Sample: 10.190.105.11:0/123,10.190.105.35:0/456,10.190.105.42:0/789 | blocklist_count=25;10;20;0;
```

---

## Threshold Recommendations

### Paused VMs

| Environment | Warning | Critical | Rationale |
|-------------|---------|----------|-----------|
| Production | 1 | 3 | Any paused VM needs immediate attention |
| Staging | 2 | 5 | Some tolerance for testing |
| Development | 5 | 10 | More relaxed for dev environments |

### Ceph Blocklist

| Environment | Warning | Critical | Rationale |
|-------------|---------|----------|-----------|
| Production | 10 | 20 | Normal CSI operations create ~5-10 entries |
| Staging | 15 | 30 | More churn in test environments |
| Development | 20 | 40 | Higher tolerance |

**Note:** Blocklist naturally grows during normal operations (CSI volume attachments). Warning at 10+ indicates potential issues. Critical at 20+ suggests systemic problems.

---

## Troubleshooting

### "oc command not found"

```bash
# Install oc CLI
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
sudo tar -xzf openshift-client-linux.tar.gz -C /usr/local/bin/ oc kubectl
sudo chmod +x /usr/local/bin/oc
```

### "jq command not found"

```bash
# RHEL/CentOS
sudo yum install -y jq

# Ubuntu/Debian
sudo apt-get install -y jq
```

### "Not logged into OpenShift cluster"

```bash
# Check current context
sudo -u nagios oc whoami

# Re-login if needed
sudo -u nagios oc login https://your-cluster:6443 --token=YOUR_TOKEN
```

### "Unable to query VirtualMachineInstances"

Check service account permissions:

```bash
# On OpenShift cluster
oc adm policy add-cluster-role-to-user cluster-reader -z icinga-monitor -n openshift-storage

# Test permissions
oc auth can-i get vmi --all-namespaces --as=system:serviceaccount:openshift-storage:icinga-monitor
```

### "Unable to query Ceph blocklist"

Check Ceph tools deployment:

```bash
# Verify rook-ceph-tools exists
oc get deployment rook-ceph-tools -n openshift-storage

# If missing, create it
oc create -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/toolbox.yaml
```

---

## Integration with Alerting

### Email Notifications

Configure in Icinga contact:

```icinga2
object User "openshift-admin" {
  display_name = "OpenShift Administrator"
  email = "admin@example.com"

  states = [ OK, Warning, Critical, Unknown ]
  types = [ Problem, Recovery ]
}
```

### Slack/PagerDuty Integration

Use Icinga notification commands:

```bash
# Example Slack notification script
/usr/lib64/nagios/plugins/send_slack_alert.sh \
  --webhook "https://hooks.slack.com/services/YOUR/WEBHOOK" \
  --service "$SERVICEDESC$" \
  --state "$SERVICESTATE$" \
  --output "$SERVICEOUTPUT$"
```

---

## Performance Data Graphing

Both scripts output performance data that can be graphed:

**Grafana with InfluxDB:**
```sql
SELECT mean("paused_vms") FROM "icinga2"
WHERE time > now() - 7d
GROUP BY time(5m)
```

**Icinga Graphite Integration:**
```
openshift.paused_vms.value
openshift.blocklist_count.value
```

---

## Automated Remediation

You can configure Icinga event handlers to auto-remediate:

```icinga2
object Service "openshift-paused-vms" {
  // ... existing config ...

  enable_event_handler = true
  event_command = "remediate_paused_vms"
}

object EventCommand "remediate_paused_vms" {
  command = [ "/usr/local/bin/fix-paused-vms.sh", "-y", "-b", "5" ]
}
```

**⚠️ Warning:** Auto-remediation should only be enabled after thorough testing.

---

## Related Documentation

- Main recovery script: `fix-paused-vms.sh`
- Continuous monitoring: `monitor-vms-and-ceph.sh`
- Root cause analysis: `ROOT-CAUSE-ANALYSIS.md`
- Quick start guide: `QUICK-START.md`

---

## Support

For issues or questions:
1. Check Icinga logs: `tail -f /var/log/icinga2/icinga2.log`
2. Test scripts manually: `sudo -u nagios /usr/lib64/nagios/plugins/check_paused_vms.sh`
3. Review OpenShift access: `sudo -u nagios oc whoami`

---

**Last Updated:** 2026-01-29
**Version:** 1.0
