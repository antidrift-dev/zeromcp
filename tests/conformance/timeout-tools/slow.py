import asyncio

tool = {
    "description": "Tool that takes 3 seconds",
    "input": {},
    "permissions": {"execute_timeout": 2},
}

async def execute(args, ctx):
    await asyncio.sleep(3)
    return {"status": "ok"}
