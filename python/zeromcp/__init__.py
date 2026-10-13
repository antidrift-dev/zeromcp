"""zeromcp — Zero-config MCP runtime for Python."""

__version__ = "0.4.0"

from .server import create_handler, serve  # noqa: F401
from .registry import create_registry  # noqa: F401
