tool = {
    "description": "Say hello to someone",
    "input": {"name": "string"},
}


async def execute(args, ctx):
    return f"Hello, {args['name']}!"
