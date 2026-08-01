import time
import os

# Same simple loop as the original systemd-based worker (Part 2).
# The only addition is touching a heartbeat file every iteration - this is
# what the readinessProbe/livenessProbe in worker-deployment.yaml check,
# since this worker doesn't expose any HTTP endpoint to probe against.
HEARTBEAT_FILE = "/tmp/healthy"

while True:
    print("Worker running", flush=True)
    with open(HEARTBEAT_FILE, "w") as f:
        f.write(str(time.time()))
    time.sleep(10)
