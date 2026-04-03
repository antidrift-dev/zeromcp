tool = {
    "description": "Add two numbers together",
    "input": {"a": "number", "b": "number"},
}


async def execute(args, ctx):
    return {"sum": args["a"] + args["b"]}
