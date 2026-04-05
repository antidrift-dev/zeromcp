tool = {
    "description": "Tool that tries a domain NOT in allowlist",
    "input": {},
    "permissions": {
        "network": ["only-this-domain.test"],
    },
}

async def execute(args, ctx):
    try:
        await ctx.fetch("http://localhost:18923/test")
        return {"bypassed": True}
    except Exception:
        return {"bypassed": False, "blocked": True}
