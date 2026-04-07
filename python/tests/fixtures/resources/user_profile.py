"""A resource template for testing."""

uri_template = "resource:///users/{user_id}/profile"
description = "User profile by ID"
mime_type = "application/json"


def read(params):
    user_id = params["user_id"]
    return f'{{"user_id": "{user_id}", "name": "User {user_id}"}}'
