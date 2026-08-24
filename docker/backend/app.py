import os

import boto3
import psycopg2
from flask import Flask, jsonify, request

app = Flask(__name__)

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
    cur.execute("insert into users (name) values (%s);", (name,))
    conn.commit()
    cur.close()
    conn.close()
    sns.publish(
        TopicArn=sns_topic_arn,
        Message=f"new user added: {name}",
        Subject="new user",
    )
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
    s3.upload_fileobj(file, s3_bucket, file.filename)
    sns.publish(
        TopicArn=sns_topic_arn,
        Message=f"file uploaded: {file.filename}",
        Subject="file upload",
    )
    return jsonify({"status": "file uploaded"})


if __name__ == "__main__":
    # noqa/nosec: binding to all interfaces is required inside a container,
    # otherwise the nginx pod could not reach this service at all.
    app.run(host="0.0.0.0", port=5000)  # nosec B104  # noqa: S104
