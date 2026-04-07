tool = {
    "description": "Echo input back",
    "input": {"message": "string"},
}


async def execute(args, ctx):
    return args["message"]
