# Placeholder. The controller's top.sls entry for this state exists from the
# start so the state tree is complete at every phase boundary; the five-minute
# sbatch loop that reports simulated job metrics to the gateway arrives with
# Phase 5, once the gateway is actually deployed and reachable.
#
# test.nop applies cleanly and reports no changes, so it costs the idempotency
# proof nothing in the meantime.

slurm-cron-placeholder:
  test.nop: []
