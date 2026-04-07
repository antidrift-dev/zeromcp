tool = {
    "description": "Dynamic test resource",
    "mimeType": "application/json",
}

async def read(ctx=None):
    return '{"dynamic": true, "timestamp": "test"}'
