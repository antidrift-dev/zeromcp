tool = {"description": "Fast tool", "input": {"name": "string"}}

async def execute(args, ctx):
    return f"Hello, {args['name']}!"
