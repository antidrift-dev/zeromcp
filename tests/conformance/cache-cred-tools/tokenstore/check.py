tool = {
    "description": "Return the current token from credentials",
    "input": {},
}


async def execute(args, ctx):
    creds = ctx.credentials
    return {"token": creds.get("token") if isinstance(creds, dict) else None}
