# SDD ledger — plan: study/plan.md
Task 1: fix round 1/5 (1 addressed, 0 open — umask window on secrets file; commits fa595cc..5614f7b)
Task 1: complete (commits fa595cc..5614f7b, review clean after fix round 1)
Task 1: minor (deferred): gen-secrets.sh cd-to-repo-root unrequested scope (accepted); slurm version quoted as string in pillar (accepted, treat as string downstream)
Task 2: fix round 1/5 (5 addressed, 0 open — dict iteration race, py2 class style, %-format, gitignore comment, TTL boundary test; commits 2d1d5cc..2005100)
Task 2: complete (commits f6ced97..2005100, review clean after fix round 1)
Task 2: minor (deferred): theoretical race where a PUT refreshing a key between snapshot and pop drops a fresh write (pre-existing, harmless at lab scale, worth one interview sentence)
Task 3: fix round 1/5 (5 addressed, 0 open — up-trigger gating, host artifacts replace, shutdown ssh race, rsync excludes, report corrections; commits 44400ec..7a641c2)
Task 3: complete (commits 44400ec..7a641c2, review clean after fix round 1)
Task 3: minor (deferred): rebuild re-runs full debuild if crash lands between cp and podman save (accepted); minion.compute.conf holds one commented literal master IP — Task 5 may collapse via minion_json_config
Task 4: dispatched and stopped 2026-08-31 12:53 before any change (migration to Ubuntu laptop); resume from task-4-brief.md + STATE.md dispatch notes
Task 4: fix round 1/5 (7 addressed, 0 open — munge:uid pillar restore, host.present clean, /var/log/slurm edges, runtime-dir pidfiles, key mode window, --pid=host, comment truth; commit 9b98340)
Task 4: fix round 2/5 (1 addressed — salt 3008 pillar masking breaks file.decode, munge key now base64 text via file.managed; found live on first controller highstate; commit 8b7966c)
Task 4: complete (merged c953b0e + fix 8b7966c; live-verified on amd64 laptop: 5 services active, cluster registered, second highstate 32/0 changed=0, one exporter container)
Task 5: authored and lead-reviewed (commit 71dd8e0, merged a51d8b9); live verification pending compute up after task 6 merge
Task 5: complete (live-verified: key auto-accepted, node idle, srun=compute, sbatch COMPLETED, second highstate changed=0)
Task 6: fix round 1/5 (11 addressed, 0 open — server-side apply for 256KB annotation cap, stamp-based release guards, tar re-import+rollout, pending unwedge, version-grep installers, repo url guard, derived flannel iface, dashboard drift guard, comment truth, pillar moves, curl refresh; commits 65eeac2..4fcac4d)
Task 6: complete (merged 14991e0; live-verified: K3s v1.36.4 Ready, kps 88.6.2 all pods Running, 14 targets 0 down, both node-exporters scraped, grafana ingress 302, both dashboards loaded; second highstate changed=0 after one transient)
Task 7: complete (chart merged 4d2542c, released by task 6 states; gateway pod Running from imported tar, PUT 204 + /metrics roundtrip, ServiceMonitor target up)
Task 8: authored + lead fix (edde489 merged ea4a4c6, curl state drop fe8ca8c); cron entry installed, manual submit_job.sh -> metrics-sim RUNNING on compute; awaiting cron-fire + prometheus series confirmation
Task 9: dispatched (verify.sh, Makefile, README)
Task 8: complete (live-verified: cron fired 11:10:02 UTC, metrics-sim jobs 3+4 on compute, all three slurm_job_* series in prometheus with slurm_job_id+node labels, controller second highstate 35/0 changed=0, exactly one crontab entry)
