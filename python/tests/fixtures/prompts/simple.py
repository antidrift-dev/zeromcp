"""A simple prompt with no arguments."""

description = "A simple prompt"


def render(args):
    return [
        {"role": "user", "content": {"type": "text", "text": "Hello!"}}
    ]
