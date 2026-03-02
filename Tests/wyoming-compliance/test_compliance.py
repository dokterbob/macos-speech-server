"""
Wyoming protocol compliance tests for macos-speech-server.

These tests require a running server. Start it with:
    swift run speech-server

Then run:
    pytest Tests/wyoming-compliance/test_compliance.py

To target a non-default host/port:
    pytest Tests/wyoming-compliance/test_compliance.py --wyoming-host=192.168.1.5 --wyoming-port=10300
"""
import asyncio
import pytest

from wyoming.client import AsyncTcpClient
from wyoming.info import Describe, Info


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def fetch_info(host: str, port: int) -> Info:
    """Connect, send describe, return parsed Info (raises on schema mismatch)."""
    async with AsyncTcpClient(host, port) as client:
        await client.write_event(Describe().event())
        event = await client.read_event()
    assert event is not None, "Server closed connection without sending a response"
    assert Info.is_type(event.type), f"Expected 'info' event, got '{event.type}'"
    # Info.from_event() will raise if the data doesn't match the schema.
    return Info.from_event(event)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@pytest.mark.integration
def test_describe_returns_valid_info(request):
    """describe → info round-trip: the server's response must parse with Info.from_event()."""
    host = request.config.getoption("--wyoming-host")
    port = request.config.getoption("--wyoming-port")
    info = asyncio.run(fetch_info(host, port))
    # If we get here without an exception the schema is valid.
    assert info is not None


@pytest.mark.integration
def test_info_advertises_asr_with_models(request):
    """The info response must include at least one ASR program with a models list."""
    host = request.config.getoption("--wyoming-host")
    port = request.config.getoption("--wyoming-port")
    info = asyncio.run(fetch_info(host, port))

    assert len(info.asr) > 0, "info.asr must be non-empty"
    asr_program = info.asr[0]
    assert asr_program.installed, "ASR program must be installed=true"
    assert len(asr_program.models) > 0, "ASR program must have at least one model"

    asr_model = asr_program.models[0]
    assert asr_model.installed, "ASR model must be installed=true"
    assert "en" in asr_model.languages, "ASR model must support English"


@pytest.mark.integration
def test_info_advertises_tts_with_alba_voice(request):
    """The info response must include a TTS program with an 'alba' voice."""
    host = request.config.getoption("--wyoming-host")
    port = request.config.getoption("--wyoming-port")
    info = asyncio.run(fetch_info(host, port))

    assert len(info.tts) > 0, "info.tts must be non-empty"
    tts_program = info.tts[0]
    assert tts_program.installed, "TTS program must be installed=true"
    assert len(tts_program.voices) > 0, "TTS program must have at least one voice"

    voice_names = [v.name for v in tts_program.voices]
    assert "alba" in voice_names, f"Expected 'alba' in voices, got {voice_names}"

    alba = next(v for v in tts_program.voices if v.name == "alba")
    assert alba.installed, "alba voice must be installed=true"
    assert "en" in alba.languages, "alba voice must support English"


@pytest.mark.integration
def test_info_empty_arrays_for_unsupported_services(request):
    """The info response must include empty arrays for handle/intent/wake/mic/snd."""
    host = request.config.getoption("--wyoming-host")
    port = request.config.getoption("--wyoming-port")
    info = asyncio.run(fetch_info(host, port))

    assert info.handle == [], f"handle must be empty, got {info.handle}"
    assert info.intent == [], f"intent must be empty, got {info.intent}"
    assert info.wake == [], f"wake must be empty, got {info.wake}"
    assert info.mic == [], f"mic must be empty, got {info.mic}"
    assert info.snd == [], f"snd must be empty, got {info.snd}"
