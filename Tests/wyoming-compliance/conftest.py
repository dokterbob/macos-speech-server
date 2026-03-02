"""Pytest configuration for Wyoming compliance tests."""
import sys
from pathlib import Path

# Add the Wyoming Python library to the path so we can import it without installing.
WYOMING_LIB = Path(__file__).parent.parent.parent.parent / "wyoming"
if WYOMING_LIB.exists():
    sys.path.insert(0, str(WYOMING_LIB))


def pytest_addoption(parser):
    parser.addoption(
        "--wyoming-host",
        default="localhost",
        help="Host where the Wyoming server is running (default: localhost)",
    )
    parser.addoption(
        "--wyoming-port",
        type=int,
        default=10300,
        help="Port where the Wyoming server is running (default: 10300)",
    )


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "integration: marks tests that require a running Wyoming server",
    )
