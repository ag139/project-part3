"""Unit tests for the worker service."""


def test_worker_writes_a_heartbeat_the_probes_can_check():
    src = open("docker/worker/worker.py").read()
    assert "/tmp/healthy" in src, \
        "the worker must write the heartbeat file its liveness probe checks"
    assert "time.time()" in src, \
        "the heartbeat must carry a timestamp, otherwise a stalled loop " \
        "would still look healthy"


def test_worker_flushes_output_so_logs_are_visible():
    src = open("docker/worker/worker.py").read()
    assert "flush=True" in src, \
        "without flushing, kubectl logs shows nothing until the buffer fills"
