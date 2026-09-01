# Task 2 report — Metrics gateway app

Branch: `worktree-agent-a31aef162c9ee9f39`
Status: DONE

## Commits

- `f6ced97` feat: metrics gateway service with prometheus exposition
- `2d1d5cc` feat: containerfile for the metrics gateway

## Files

- `gateway/app.py` (87 lines)
- `gateway/test_app.py` (121 lines, 28 test cases via parametrize)
- `gateway/requirements.txt`
- `gateway/Containerfile`
- `.gitignore` — added `gateway/.venv/`, `__pycache__/`, `.pytest_cache/`

## Pinned versions (checked against PyPI at implementation time, 2026-08-31)

```
flask==3.1.3
prometheus-client==0.26.0
```

`pytest` (9.1.1) is installed into the venv on the command line only. It is not in
`requirements.txt`, because that file is what the Containerfile installs and the
image has no business carrying a test runner.

## TDD evidence

### RED — tests written before any implementation

```
$ cd gateway && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt pytest && .venv/bin/pytest -q
==================================== ERRORS ====================================
_________________________ ERROR collecting test_app.py _________________________
ImportError while importing test module '.../gateway/test_app.py'.
Traceback:
test_app.py:4: in <module>
    import app as gateway
E   ModuleNotFoundError: No module named 'app'
=========================== short test summary info ============================
ERROR test_app.py
!!!!!!!!!!!!!!!!!!!! Interrupted: 1 error during collection !!!!!!!!!!!!!!!!!!!!
1 error in 0.11s
```

### GREEN — after writing `gateway/app.py`

```
$ cd gateway && .venv/bin/pytest -q
............................                                             [100%]
28 passed in 0.46s
```

Pristine: no warnings, no skips, no xfails.

### Real-server smoke check (beyond the Flask test client)

Started `python app.py` with `PORT=8099` in a subprocess and drove it over HTTP, so the
`__main__` / `PORT` path the container actually uses is verified too:

```
PUT -> 204
Content-Type: text/plain; version=1.0.0; charset=utf-8
# HELP slurm_job_cpu_percent Reported via the metrics gateway
# TYPE slurm_job_cpu_percent gauge
slurm_job_cpu_percent{node="compute",slurm_job_id="42"} 42.0
```

## Contract coverage

| Brief clause | Test |
|---|---|
| PUT then `/metrics` contains `slurm_job_cpu_percent{...} 42.0` | `test_put_then_scrape_roundtrip` |
| `CONTENT_TYPE_LATEST` on `/metrics` | asserted in the shared `scrape()` helper, so every scrape test checks it |
| Exposition carries only our series (fresh registry, no default collectors) | `test_scrape_exposes_only_reported_series` |
| Same label names, different values = separate series | `test_same_label_names_different_values_are_separate_series` |
| Repeated PUT overwrites value, does not duplicate the series | `test_repeated_put_overwrites_value` |
| Conflicting label-name set for one metric -> 400 | `test_conflicting_label_names_rejected` |
| Non-numeric value -> 400 (incl. bool, which is not a number here) | `test_non_numeric_value_rejected` (5 cases: `"42"`, `null`, `true`, list, object) |
| Name failing `^[a-zA-Z_:][a-zA-Z0-9_:]*$` -> 400 | `test_invalid_metric_name_rejected` (6 cases incl. non-string) |
| Missing `name`/`value`/`labels`, non-dict labels, invalid label name -> 400 | `test_malformed_payload_rejected` (5 cases) |
| Unparseable / non-JSON body -> 400 | `test_non_json_body_rejected` |
| Label values coerced to `str` | `test_label_values_coerced_to_string` |
| 405 on non-PUT to `/update-metric` | `test_non_put_method_not_allowed` (GET, POST, DELETE) |
| TTL expiry checked at scrape time | `test_series_expires_after_ttl` — monkeypatched clock, asserts alive at `TTL-1` and gone at `TTL+1` |
| PUT refreshes the timestamp | `test_put_refreshes_expiry` |

## Design notes

- **Clock seam.** `app.now = time.time` is a module-level name that every call site
  resolves at call time, so tests do `monkeypatch.setattr(gateway, "now", ...)`
  instead of patching the stdlib `time` module out from under pytest itself.
- **Store shape.** `series[(name, tuple(sorted(labels.items())))] = (value, labels, updated)`.
  The brief sketched `tuple(sorted(labels))`, which keys on label *names* only and would
  collapse `slurm_job_id=1` and `slurm_job_id=2` into one series; keying on the sorted
  `items()` gives the required "same names, different values = separate series".
- **Label-name registry.** `label_names[name] -> frozenset` is populated by `validate()`
  via `setdefault` and is deliberately never pruned, so a metric name keeps one label
  shape for the life of the process even after all its series expire. Changing the label
  set of a live metric name is exactly the thing Prometheus cannot represent, so locking
  it is the correct behavior, not just the lazy one. A one-line comment in the code says so.
- **Expiry runs inside `collect()`**, deleting stale keys before building families, so
  a scrape both prunes and reports — no background thread, no timer, per the brief.
- **Fresh `CollectorRegistry`.** Nothing is registered on the default registry, so the
  exposition never leaks `python_gc_*` / `process_*`. Asserted, not assumed.
- **Label name validation** (`^[a-zA-Z_][a-zA-Z0-9_]*$`) is not in the brief's 400 list
  but is input validation at a trust boundary: an unchecked label name would emit
  syntactically invalid exposition text and break the scrape for every other series.
- **`import sys`** is present and unnoted, per locked decision 8. No linter config was
  added anywhere in the repo.

## Deliberately not built (YAGNI)

- No `/healthz`. Drafted it, then cut it — nothing asked for it, and a k8s probe can
  hit `/metrics`. Add it if the Task 5 chart wants a probe that does not scrape.
- No gunicorn/waitress. Single-process Flask dev server is the locked lab decision;
  the README limitation note is a later task's job.
- No persistence, no locking, no threads.
- No `conftest.py` — pytest's rootdir insertion already puts `gateway/` on `sys.path`.

## Not done here, by instruction

The image is **not** built. `podman build` runs on the builder VM in Task 3.

## Follow-ups for later tasks

- The chart's ServiceMonitor must target the port name the Deployment exposes for 8080,
  and must carry the kube-prometheus-stack release label (CLAUDE.md trap).
- `METRIC_TTL_SECONDS` and `PORT` should come from pillar -> chart values, not be
  hardcoded in the Deployment (repo convention: every tunable lives in pillar).
- README limitations section should state: single process, in-memory store, dev server,
  metrics lost on pod restart, TTL-based expiry.
- The host venv (`gateway/.venv`) was created with the host's Python 3.14; the image
  pins 3.12-slim per the brief. Nothing in the app is version-sensitive, but the test
  run proving green happened on 3.14.

---

# Fix report — review round 1

Commit: `2005100` fix: snapshot the metric store while collecting

## Important — collector iterated the live dict (app.py:50)

`StoreCollector.collect()` pruned expired keys from a `list()` snapshot but then
iterated `series.items()` directly to build the families. `app.run()` is
`threaded=True` by default, so a PUT landing between those two loops mutated the dict
mid-iteration and raised `RuntimeError: dictionary changed size during iteration`,
which fails the entire `/metrics` response — every series, not just the new one.

Fixed by collapsing prune and read into one pass over a single `list()` snapshot:

```python
deadline = now() - TTL
by_name = {}
# The builtin server is threaded, so a PUT can land mid-scrape. Both the
# prune and the read walk one snapshot; the live dict is never iterated.
for key, (value, labels, updated) in list(series.items()):
    if updated < deadline:
        series.pop(key, None)
    else:
        by_name.setdefault(key[0], []).append((labels, value))
```

Two details beyond the literal fix:

- One pass instead of two. The second loop existed only because the first one was a
  prune; merging them removes the window entirely rather than papering over it.
- `series.pop(key, None)` rather than `del series[key]`. A concurrent PUT can only add
  or overwrite, but two concurrent scrapes can both decide the same key is expired, and
  the loser of that race would hit `KeyError`. Same line length, correct on the edge.

No locks. CPython dict get/set/pop are atomic under the GIL, and the store's only
consistency requirement is that a scrape sees each series either before or after a
given PUT, which a snapshot gives.

## Minors applied

- `class StoreCollector(object)` -> `class StoreCollector`.
- Three `%`-format validation messages -> f-strings (app.py:31, 37, 39).
- `.gitignore` comment now reads "Host-side Python test artifacts: the gateway venv,
  bytecode, pytest state. None of it is shipped in the container image." — it heads a
  block covering all three, not just the venv.

## Optional item taken: TTL boundary

Added to `test_series_expires_after_ttl`, which now pins all three points around the
boundary rather than only straddling it:

| Age of entry at scrape | Expected |
|---|---|
| `TTL - 1` | present |
| exactly `TTL` | present |
| `TTL + 1` | gone |

The middle row is the one that was unpinned. Expiry is `updated < now() - TTL`, so age
*greater than* TTL expires and an entry exactly TTL seconds old survives; that is now a
test rather than an implementation accident. Skipped the concurrent-PUT-during-scrape
test as advised — it cannot be made deterministic without threading machinery worth
more than the assertion.

## Verification

```
$ cd gateway && .venv/bin/pytest -q
............................                                             [100%]
28 passed in 0.19s
```

Same 28 cases (the boundary check is an extra assertion inside an existing test, not a
new case). No warnings, no skips.

Real-server smoke re-run against `python app.py` on `PORT=8099`, unchanged:

```
PUT -> 204
Content-Type: text/plain; version=1.0.0; charset=utf-8
# HELP slurm_job_cpu_percent Reported via the metrics gateway
# TYPE slurm_job_cpu_percent gauge
slurm_job_cpu_percent{node="compute",slurm_job_id="42"} 42.0
```
