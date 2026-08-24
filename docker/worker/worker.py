import time

# Same simple loop as the original systemd-based worker (Part 2).
# The only addition is touching a heartbeat file every iteration - this is
# what the readinessProbe/livenessProbe in worker-deployment.yaml check,
# since this worker doesn't expose any HTTP endpoint to probe against.
# The path is fixed on purpose: the readiness and liveness probes in
# worker-deployment.yaml check this exact file, and /tmp is the only
# writable mount on a read-only root filesystem.
HEARTBEAT_FILE = "/tmp/healthy"  # nosec B108  # noqa: S108

while True:
    print("Worker running", flush=True)
    with open(HEARTBEAT_FILE, "w") as f:
        f.write(str(time.time()))
    time.sleep(10)
