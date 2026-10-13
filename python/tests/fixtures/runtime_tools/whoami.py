tool = {
    "description": "Return ctx.runtime",
    "input": {},
}


async def execute(args, ctx):
    return {"runtime": ctx.runtime}
