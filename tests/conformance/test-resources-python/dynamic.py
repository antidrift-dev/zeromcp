description = "Dynamic test resource"
mime_type = "application/json"

async def read():
    return '{"dynamic": true, "timestamp": "test"}'
