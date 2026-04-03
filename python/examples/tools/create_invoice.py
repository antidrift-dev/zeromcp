import time
from datetime import datetime, timezone

tool = {
    "description": "Create an invoice",
    "input": {
        "customer_id": "string",
        "amount": "number",
    },
}


async def execute(args, ctx):
    return {
        "id": f"inv_{int(time.time() * 1000)}",
        "customer_id": args["customer_id"],
        "amount": args["amount"],
        "status": "draft",
        "created": datetime.now(timezone.utc).isoformat(),
    }
