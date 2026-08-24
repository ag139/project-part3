import os
import sys
import types

import pytest

REQUIRED_ENV = {
    "DB_HOST": "localhost",
    "DB_PORT": "5432",
    "DB_NAME": "testdb",
    "DB_USER": "testuser",
    "DB_PASSWORD": "testpass",
    "S3_BUCKET_NAME": "test-bucket",
    "SNS_TOPIC_ARN": "arn:aws:sns:us-east-1:000000000000:test-topic",
    "AWS_REGION": "us-east-1",
}


class FakeCursor:
    def __init__(self, rows):
        self.rows = rows
        self.executed = []
        self.closed = False

    def execute(self, query, params=None):
        self.executed.append((query, params))

    def fetchall(self):
        return self.rows

    def close(self):
        self.closed = True


class FakeConnection:
    def __init__(self, rows=None):
        self.cursor_obj = FakeCursor(rows or [])
        self.committed = False
        self.closed = False

    def cursor(self):
        return self.cursor_obj

    def commit(self):
        self.committed = True

    def close(self):
        self.closed = True


class FakeAwsClient:
    def __init__(self):
        self.published = []
        self.uploaded = []
        self.fail = False

    def publish(self, **kwargs):
        if self.fail:
            raise RuntimeError("SNS unavailable")
        self.published.append(kwargs)
        return {"MessageId": "fake"}

    def upload_fileobj(self, fileobj, bucket, key):
        if self.fail:
            raise RuntimeError("S3 unavailable")
        self.uploaded.append((bucket, key))


@pytest.fixture
def app_module(monkeypatch):
    """Import app.py with the environment set and AWS and the database faked."""
    for key, value in REQUIRED_ENV.items():
        monkeypatch.setenv(key, value)

    fake_s3 = FakeAwsClient()
    fake_sns = FakeAwsClient()

    fake_boto3 = types.ModuleType("boto3")

    def client(service, **kwargs):
        return {"s3": fake_s3, "sns": fake_sns}[service]

    fake_boto3.client = client
    monkeypatch.setitem(sys.modules, "boto3", fake_boto3)

    fake_conn = FakeConnection()
    fake_psycopg2 = types.ModuleType("psycopg2")
    fake_psycopg2.connect = lambda **kwargs: fake_conn
    monkeypatch.setitem(sys.modules, "psycopg2", fake_psycopg2)

    sys.path.insert(0, os.path.join(os.getcwd(), "docker", "backend"))
    for name in ("app",):
        sys.modules.pop(name, None)
    import app as app_mod

    app_mod._fake_s3 = fake_s3
    app_mod._fake_sns = fake_sns
    app_mod._fake_conn = fake_conn
    return app_mod


@pytest.fixture
def client(app_module):
    app_module.app.config["TESTING"] = True
    return app_module.app.test_client()
