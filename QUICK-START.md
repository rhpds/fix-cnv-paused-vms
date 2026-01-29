# Quick Start Guide

## 🆘 Emergency: VMs Are Paused RIGHT NOW

```bash
# 1. Quick check
oc get vmi --all-namespaces | grep False

# 2. Verify Ceph is healthy
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph -s

# 3. Run recovery (if Ceph shows HEALTH_OK)
cd fix-cnv-paused-vms
./fix-paused-vms.sh -y
```

That's it! The script will:
- Find paused VMs
- Clear blocklists (only for affected nodes)
- Restart VMs in batches
- Verify recovery

---

## 🔍 Want to Investigate What Happened?

```bash
# Run the incident investigation
./investigate-incident.sh

# Diagnose the problematic node
./diagnose-node.sh ocp-virt4-ceph7

# Read the full analysis
cat ROOT-CAUSE-ANALYSIS.md
```

---

## 📊 Want to Monitor Going Forward?

```bash
# Run monitoring every 5 minutes
./monitor-vms-and-ceph.sh --loop 300

# With Slack alerts (replace with your webhook)
./monitor-vms-and-ceph.sh --loop 300 --webhook https://hooks.slack.com/your-url
```

---

## 📖 Need More Details?

See `README.md` for complete documentation.

---

## Common Questions

**Q: Is it safe to run fix-paused-vms.sh?**  
A: Yes! It only clears blocklists for nodes hosting paused VMs, not all entries.

**Q: Will it restart ALL my VMs?**  
A: No, only VMs that are currently paused.

**Q: Can I run it on a single namespace?**  
A: Yes! Use: `./fix-paused-vms.sh -n your-namespace`

**Q: How long does recovery take?**  
A: Default is 10 VMs every 60 seconds. For 100 VMs, about 15-20 minutes.
