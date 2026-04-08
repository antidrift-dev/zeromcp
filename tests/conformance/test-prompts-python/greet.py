description = "Greeting prompt"
arguments = {
    "name": "string",
    "tone": {"type": "string", "optional": True, "description": "formal or casual"},
}

async def render(args):
    name = args.get("name", "world")
    tone = args.get("tone", "casual")
    return [
        {"role": "user", "content": {"type": "text", "text": f"Greet {name} in a {tone} tone"}},
    ]
