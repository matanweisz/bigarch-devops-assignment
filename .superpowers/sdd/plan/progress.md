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
