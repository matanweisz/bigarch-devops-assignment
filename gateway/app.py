import os
import re
import sys
import time

from flask import Flask, request
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, generate_latest
from prometheus_client.core import GaugeMetricFamily

METRIC_NAME_RE = re.compile(r"^[a-zA-Z_:][a-zA-Z0-9_:]*$")
LABEL_NAME_RE = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")
TTL = float(os.environ.get("METRIC_TTL_SECONDS", "300"))

# (name, sorted label pairs) -> (value, labels, last update). Single process, in
# memory on purpose: a scrape target that outlives the job it reports is worse
# than one that forgets.
series = {}
# name -> label name set. A metric may not change its label names mid-flight;
# never pruned, so the first shape a name is seen with wins for the process life.
label_names = {}

# Indirected so tests can drive the clock.
now = time.time


def validate(payload):
    if not isinstance(payload, dict):
        return "body must be a JSON object"
    name, value, labels = payload.get("name"), payload.get("value"), payload.get("labels")
    if not isinstance(name, str) or not METRIC_NAME_RE.match(name):
        return "name must match %s" % METRIC_NAME_RE.pattern
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return "value must be a number"
    if not isinstance(labels, dict):
        return "labels must be an object"
    if not all(isinstance(k, str) and LABEL_NAME_RE.match(k) for k in labels):
        return "label names must match %s" % LABEL_NAME_RE.pattern
    if label_names.setdefault(name, frozenset(labels)) != frozenset(labels):
        return "%s is already reported with labels %s" % (name, sorted(label_names[name]))
    return None


class StoreCollector(object):
    def collect(self):
        deadline = now() - TTL
        for key, (_, _, updated) in list(series.items()):
            if updated < deadline:
                del series[key]
        by_name = {}
        for (name, _), (value, labels, _) in series.items():
            by_name.setdefault(name, []).append((labels, value))
        for name, points in by_name.items():
            names = sorted(label_names[name])
            gauge = GaugeMetricFamily(name, "Reported via the metrics gateway", labels=names)
            for labels, value in points:
                gauge.add_metric([labels[n] for n in names], value)
            yield gauge


registry = CollectorRegistry()
registry.register(StoreCollector())

app = Flask(__name__)


@app.route("/update-metric", methods=["PUT"])
def update_metric():
    payload = request.get_json(silent=True)
    error = validate(payload)
    if error:
        return {"error": error}, 400
    labels = {k: str(v) for k, v in payload["labels"].items()}
    series[(payload["name"], tuple(sorted(labels.items())))] = (
        float(payload["value"]),
        labels,
        now(),
    )
    return "", 204


@app.route("/metrics")
def metrics():
    return generate_latest(registry), 200, {"Content-Type": CONTENT_TYPE_LATEST}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
