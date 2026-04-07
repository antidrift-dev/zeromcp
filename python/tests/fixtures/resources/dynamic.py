"""A dynamic resource for testing."""

uri = "resource:///dynamic-data"
description = "Dynamic test resource"
mime_type = "application/json"


def read():
    return '{"status": "ok"}'
