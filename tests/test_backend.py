"""Unit tests for the backend service.

Covers route behaviour, configuration handling and failure cases.
The database and the AWS clients are replaced with fakes in conftest.py,
so these tests need no infrastructure.
"""
import importlib
import os
import sys
import types

import pytest

# ---------------------------------------------------------------- routes

def test_health_returns_200_and_expected_body(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.get_json() == {"message": "app is running"}


def test_health_does_not_touch_the_database(client, app_module):
    client.get("/")
    assert app_module._fake_conn.cursor_obj.executed == [], \
        "the health check must not query the database, or a database outage " \
        "would fail the liveness probe and kill healthy pods"


def test_add_user_inserts_and_publishes(client, app_module):
    resp = client.post("/add_user", json={"name": "alice"})
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "user added"}

    executed = app_module._fake_conn.cursor_obj.executed
    assert len(executed) == 1
    query, params = executed[0]
    assert "insert into users" in query.lower()
    assert params == ("alice",)
    assert app_module._fake_conn.committed is True
    assert len(app_module._fake_sns.published) == 1


def test_add_user_uses_a_parameter_not_string_concatenation(client, app_module):
    """Guards against SQL injection through the name field."""
    client.post("/add_user", json={"name": "'; DROP TABLE users; --"})
    query, params = app_module._fake_conn.cursor_obj.executed[0]
    assert "DROP TABLE" not in query, \
        "the value was concatenated into the query instead of being parameterised"
    assert params == ("'; DROP TABLE users; --",)


def test_get_users_returns_rows(client, app_module):
    app_module._fake_conn.cursor_obj.rows = [[1, "alice"], [2, "bob"]]
    resp = client.get("/users")
    assert resp.status_code == 200
    assert resp.get_json() == [[1, "alice"], [2, "bob"]]


def test_upload_without_a_file_returns_400(client):
    resp = client.post("/upload")
    assert resp.status_code == 400
    assert "error" in resp.get_json()


def test_upload_stores_the_file_and_publishes(client, app_module):
    import io
    data = {"file": (io.BytesIO(b"hello"), "note.txt")}
    resp = client.post("/upload", data=data, content_type="multipart/form-data")
    assert resp.status_code == 200
    assert app_module._fake_s3.uploaded == [("test-bucket", "note.txt")]
    assert len(app_module._fake_sns.published) == 1


# ------------------------------------------------------- failure cases

def test_add_user_surfaces_a_notification_failure(app_module):
    """A notification failure must not be swallowed.

    The exception has to propagate, because in production Flask turns an
    unhandled exception into a 500 rather than reporting success.
    """
    app_module.app.config["TESTING"] = False
    app_module._fake_sns.fail = True
    resp = app_module.app.test_client().post("/add_user", json={"name": "carol"})
    assert resp.status_code == 500


def test_upload_surfaces_a_storage_failure(app_module):
    """A storage failure must not be reported as a successful upload."""
    import io
    app_module.app.config["TESTING"] = False
    app_module._fake_s3.fail = True
    data = {"file": (io.BytesIO(b"hello"), "note.txt")}
    resp = app_module.app.test_client().post(
        "/upload", data=data, content_type="multipart/form-data")
    assert resp.status_code == 500


# ------------------------------------------------- configuration source

def test_required_configuration_comes_from_the_environment(monkeypatch):
    """Removing a required variable must fail loudly at import time."""
    from tests.conftest import REQUIRED_ENV

    for key, value in REQUIRED_ENV.items():
        monkeypatch.setenv(key, value)
    monkeypatch.delenv("DB_PASSWORD", raising=False)

    fake_boto3 = types.ModuleType("boto3")
    fake_boto3.client = lambda service, **kw: None
    monkeypatch.setitem(sys.modules, "boto3", fake_boto3)
    fake_psycopg2 = types.ModuleType("psycopg2")
    fake_psycopg2.connect = lambda **kw: None
    monkeypatch.setitem(sys.modules, "psycopg2", fake_psycopg2)

    sys.path.insert(0, os.path.join(os.getcwd(), "docker", "backend"))
    sys.modules.pop("app", None)

    with pytest.raises(KeyError):
        importlib.import_module("app")


def test_optional_configuration_has_a_default(app_module):
    assert app_module.rds_port == "5432"
    assert app_module.aws_region == "us-east-1"


def test_source_contains_no_hardcoded_credentials():
    src = open("docker/backend/app.py").read()
    assert "AKIA" not in src, "a hardcoded AWS access key is present"
    assert "rds.amazonaws.com" not in src, "a hardcoded database endpoint is present"
    assert "password=\"" not in src.replace("password=rds_pass", ""), \
        "a literal password appears in the source"
