### Task 2: Metrics gateway app (pure Python, host-testable)

**Files:**
- Create: `gateway/app.py`, `gateway/requirements.txt`, `gateway/test_app.py`, `gateway/Containerfile`

**Interfaces (produced):**
- `PUT /update-metric` accepts JSON `{"name": str, "value": number, "labels": {str: str}}` -> 204; 400 on bad name/value/label-name-set conflict; 405 on other methods.
- `GET /metrics` -> Prometheus text format, `CONTENT_TYPE_LATEST`.
- Entries expire after `METRIC_TTL_SECONDS` (env, default 300) — checked at scrape time.
- App listens on `0.0.0.0:8080` (env `PORT`). Container runs `python app.py` (single process, Flask builtin server is acceptable for this lab; note in README limitations).

- [ ] Write `gateway/requirements.txt`: `flask` and `prometheus-client` pinned to current versions (check pypi at implementation time).
- [ ] Write `gateway/test_app.py` first (pytest, Flask test client): PUT then /metrics roundtrip contains `slurm_job_cpu_percent{...} 42.0`; PUT with conflicting label names for same metric -> 400; PUT non-numeric value -> 400; metric name failing `^[a-zA-Z_:][a-zA-Z0-9_:]*$` -> 400; monkeypatched clock past TTL -> series gone from /metrics.
- [ ] Run `cd gateway && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt pytest && .venv/bin/pytest -q` — must fail (no app yet). Add `gateway/.venv` to `.gitignore`.
- [ ] Write `gateway/app.py`: `import sys` among imports (no comment — assignment instruction); store `{(name, tuple(sorted(labels))): (value, labels, timestamp)}` plus a `{name: frozenset(label_names)}` registry; custom collector yields `GaugeMetricFamily` per name with label values, skipping expired entries; Flask routes as above. Target ~80 lines.
- [ ] Pytest green. Commit.
- [ ] Write `Containerfile`: `FROM docker.io/python:3.12-slim`, copy requirements + install, copy app.py, non-root user, `EXPOSE 8080`, `CMD ["python", "app.py"]`. (Build happens on the builder VM in Task 3 — do not build on the host.) Commit.

