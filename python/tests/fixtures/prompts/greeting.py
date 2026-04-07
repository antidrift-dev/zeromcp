"""A prompt for testing."""

description = "Generate a greeting"
arguments = {
    "name": "string",
    "style": {"type": "string", "description": "Greeting style", "optional": True},
}


def render(args):
    name = args.get("name", "World")
    style = args.get("style", "formal")
    return [
        {"role": "user", "content": {"type": "text", "text": f"Greet {name} in a {style} style."}}
    ]
