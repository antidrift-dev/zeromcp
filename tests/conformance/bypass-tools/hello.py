tool = {"description": "Say hello", "input": {"name": "string"}}

async def execute(args, ctx):
    return f"Hello, {args['name']}!"
