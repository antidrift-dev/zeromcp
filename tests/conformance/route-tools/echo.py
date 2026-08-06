tool = {
    "description": "Echo a message",
    "input": {"message": "string"},
    "route": {"method": "POST", "path": "/echo"},
}


async def execute(args, ctx):
    return {"message": args["message"], "echoed": True}
