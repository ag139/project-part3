import os
import time

import boto3
import psycopg2
from flask import Flask, Response, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    Info,
    generate_latest,
)

app = Flask(__name__)

http_requests_total = Counter(
    "http_requests_total",
    "Total HTTP requests handled, by endpoint, method and status.",
    ["endpoint", "method", "status"],
)

http_request_duration_seconds = Histogram(
    "http_request_duration_seconds",
    "Request duration in seconds, by endpoint.",
    ["endpoint"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)

http_requests_in_flight = Gauge(
    "http_requests_in_flight",
    "Requests currently being processed.",
)

users_registered_total = Counter(
    "users_registered_total",
    "Users successfully written to the database.",
)

files_uploaded_total = Counter(
    "files_uploaded_total",
    "Files successfully stored in object storage.",
)

dependency_failures_total = Counter(
    "dependency_failures_total",
    "Calls to an external dependency that raised, by dependency.",
    ["dependency"],
)

app_info = Info(
    "app",
    "Build and release identity of the running instance.",
)
app_info.info(
    {
        "version": os.environ.get("APP_VERSION", "unknown"),
        "git_sha": os.environ.get("GIT_SHA", "unknown"),
        "release": os.environ.get("RELEASE", "unknown"),
    }
)

# All values now come from the environment - ConfigMap for non-sensitive
# config, Secret for credentials. Nothing sensitive is hardcoded or baked
# into the Docker image anymore.
rds_host = os.environ["DB_HOST"]
rds_port = os.environ.get("DB_PORT", "5432")
rds_db = os.environ["DB_NAME"]
rds_user = os.environ["DB_USER"]
rds_pass = os.environ["DB_PASSWORD"]

s3_bucket = os.environ["S3_BUCKET_NAME"]
sns_topic_arn = os.environ["SNS_TOPIC_ARN"]
aws_region = os.environ.get("AWS_REGION", "us-east-1")

# boto3 automatically picks up AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# from the environment (set via the app-secrets Secret) - no code change
# needed there, just don't pass credentials explicitly here.
s3 = boto3.client("s3", region_name=aws_region)
sns = boto3.client("sns", region_name=aws_region)


@app.before_request
def _start_timer():
    request._start_time = time.perf_counter()
    if request.path != "/metrics":
        http_requests_in_flight.inc()


@app.after_request
def _record_request(response):
    if request.path == "/metrics":
        return response
    endpoint = request.endpoint or "unknown"
    elapsed = time.perf_counter() - getattr(request, "_start_time", time.perf_counter())
    http_request_duration_seconds.labels(endpoint=endpoint).observe(elapsed)
    http_requests_total.labels(
        endpoint=endpoint,
        method=request.method,
        status=str(response.status_code),
    ).inc()
    http_requests_in_flight.dec()
    return response


@app.route("/metrics", methods=["GET"])
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


def get_connection():
    return psycopg2.connect(
        host=rds_host,
        port=rds_port,
        database=rds_db,
        user=rds_user,
        password=rds_pass,
    )


@app.route("/", methods=["GET"])
def home():
    return jsonify({"message": "app is running"})


@app.route("/add_user", methods=["POST"])
def add_user():
    data = request.get_json()
    name = data.get("name")
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("insert into users (name) values (%s);", (name,))
        conn.commit()
    except Exception:
        dependency_failures_total.labels(dependency="database").inc()
        raise
    finally:
        cur.close()
        conn.close()
    users_registered_total.inc()
    try:
        sns.publish(
            TopicArn=sns_topic_arn,
            Message=f"new user added: {name}",
            Subject="new user",
        )
    except Exception:
        dependency_failures_total.labels(dependency="sns").inc()
        raise
    return jsonify({"status": "user added"})


@app.route("/users", methods=["GET"])
def get_users():
    conn = get_connection()
    cur = conn.cursor()
    cur.execute("select * from users;")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify(rows)


@app.route("/upload", methods=["POST"])
def upload_file():
    if "file" not in request.files:
        return jsonify({"error": "no file"}), 400
    file = request.files["file"]
    try:
        s3.upload_fileobj(file, s3_bucket, file.filename)
    except Exception:
        dependency_failures_total.labels(dependency="s3").inc()
        raise
    files_uploaded_total.inc()
    try:
        sns.publish(
            TopicArn=sns_topic_arn,
            Message=f"file uploaded: {file.filename}",
            Subject="file upload",
        )
    except Exception:
        dependency_failures_total.labels(dependency="sns").inc()
        raise
    return jsonify({"status": "file uploaded"})


if __name__ == "__main__":
    # noqa/nosec: binding to all interfaces is required inside a container,
    # otherwise the nginx pod could not reach this service at all.
    app.run(host="0.0.0.0", port=5000)  # nosec B104  # noqa: S104
