tool = {
    "description": "Greet someone by name",
    "input": {"name": "string"},
    "route": {"method": "GET", "path": "/greet/:name"},
}


async def execute(args, ctx):
    return f"Hello, {args['name']}!"
