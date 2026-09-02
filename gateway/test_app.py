import pytest
from prometheus_client import CONTENT_TYPE_LATEST

import app as gateway

CPU = "slurm_job_cpu_percent"
LABELS = {"slurm_job_id": "42", "node": "compute"}


@pytest.fixture
def client():
    gateway.series.clear()
    gateway.label_names.clear()
    return gateway.app.test_client()


def put(client, **payload):
    return client.put("/update-metric", json=payload)


def scrape(client):
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert resp.headers["Content-Type"] == CONTENT_TYPE_LATEST
    return resp.get_data(as_text=True)


def test_put_then_scrape_roundtrip(client):
    assert put(client, name=CPU, value=42, labels=LABELS).status_code == 204
    body = scrape(client)
    assert 'slurm_job_cpu_percent{node="compute",slurm_job_id="42"} 42.0' in body


def test_scrape_exposes_only_reported_series(client):
    put(client, name=CPU, value=1.5, labels=LABELS)
    body = scrape(client)
    assert "python_gc" not in body
    assert "process_cpu_seconds_total" not in body


def test_same_label_names_different_values_are_separate_series(client):
    put(client, name=CPU, value=1, labels={"slurm_job_id": "1", "node": "compute"})
    put(client, name=CPU, value=2, labels={"slurm_job_id": "2", "node": "compute"})
    body = scrape(client)
    assert 'slurm_job_cpu_percent{node="compute",slurm_job_id="1"} 1.0' in body
    assert 'slurm_job_cpu_percent{node="compute",slurm_job_id="2"} 2.0' in body


def test_repeated_put_overwrites_value(client):
    put(client, name=CPU, value=1, labels=LABELS)
    put(client, name=CPU, value=9, labels=LABELS)
    body = scrape(client)
    assert 'slurm_job_cpu_percent{node="compute",slurm_job_id="42"} 9.0' in body
    assert body.count("slurm_job_cpu_percent{") == 1


def test_conflicting_label_names_rejected(client):
    assert put(client, name=CPU, value=1, labels={"node": "compute"}).status_code == 204
    assert put(client, name=CPU, value=1, labels={"host": "compute"}).status_code == 400


@pytest.mark.parametrize("value", ["42", None, True, [1], {"a": 1}])
def test_non_numeric_value_rejected(client, value):
    assert put(client, name=CPU, value=value, labels=LABELS).status_code == 400


@pytest.mark.parametrize("name", ["1bad", "bad-name", "bad name", "", "a.b", 7])
def test_invalid_metric_name_rejected(client, name):
    assert put(client, name=name, value=1, labels=LABELS).status_code == 400


@pytest.mark.parametrize(
    "payload",
    [
        {"value": 1, "labels": {}},
        {"name": CPU, "labels": {}},
        {"name": CPU, "value": 1},
        {"name": CPU, "value": 1, "labels": ["node"]},
        {"name": CPU, "value": 1, "labels": {"1bad": "x"}},
    ],
)
def test_malformed_payload_rejected(client, payload):
    assert client.put("/update-metric", json=payload).status_code == 400


def test_non_json_body_rejected(client):
    resp = client.put("/update-metric", data="not json", content_type="text/plain")
    assert resp.status_code == 400


def test_label_values_coerced_to_string(client):
    assert put(client, name=CPU, value=1, labels={"slurm_job_id": 42}).status_code == 204
    assert 'slurm_job_cpu_percent{slurm_job_id="42"} 1.0' in scrape(client)


@pytest.mark.parametrize("method", ["get", "post", "delete"])
def test_non_put_method_not_allowed(client, method):
    assert getattr(client, method)("/update-metric").status_code == 405


def test_series_expires_after_ttl(client, monkeypatch):
    clock = [1000.0]
    monkeypatch.setattr(gateway, "now", lambda: clock[0])
    put(client, name=CPU, value=42, labels=LABELS)

    clock[0] = 1000.0 + gateway.TTL - 1
    assert "slurm_job_cpu_percent" in scrape(client)

    # An entry exactly TTL seconds old is still live. Expiry is age > TTL.
    clock[0] = 1000.0 + gateway.TTL
    assert "slurm_job_cpu_percent" in scrape(client)

    clock[0] = 1000.0 + gateway.TTL + 1
    assert "slurm_job_cpu_percent" not in scrape(client)


def test_put_refreshes_expiry(client, monkeypatch):
    clock = [1000.0]
    monkeypatch.setattr(gateway, "now", lambda: clock[0])
    put(client, name=CPU, value=42, labels=LABELS)

    clock[0] += gateway.TTL - 1
    put(client, name=CPU, value=43, labels=LABELS)
    clock[0] += 2
    assert 'slurm_job_cpu_percent{node="compute",slurm_job_id="42"} 43.0' in scrape(client)
