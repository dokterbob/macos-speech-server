#!/usr/bin/env python3
"""Persistent JSON-lines Misaki English G2P worker for macos-speech-server."""

import json
import re
import sys
import warnings

warnings.filterwarnings("ignore", category=FutureWarning)

from misaki import en, espeak

_PRONUNCIATION_REPLACEMENTS = (
    (re.compile(r"\bCO[2₂]\b"), "C O 2"),
    (re.compile(r"\bCO\b"), "C O"),
    (re.compile(r"\bTVOC\b"), "T V O C"),
    (re.compile(r"\bVOC\b"), "V O C"),
    (re.compile(r"\bAQI\b"), "A Q I"),
    (re.compile(r"\bPM2\.5\b"), "P M two point five"),
    (re.compile(r"\bPM10\b"), "P M 10"),
    (re.compile(r"\bPM1\b"), "P M 1"),
    (re.compile(r"\bLG\b"), "L G"),
    (re.compile(r"\bHVAC\b"), "H V A C"),
)


def _normalize_pronunciation(text: str) -> str:
    for pattern, replacement in _PRONUNCIATION_REPLACEMENTS:
        text = pattern.sub(replacement, text)
    return text


def main() -> None:
    fb_us = espeak.EspeakFallback(british=False)
    fb_gb = espeak.EspeakFallback(british=True)
    g2p_us = en.G2P(trf=False, british=False, fallback=fb_us)
    g2p_gb = en.G2P(trf=False, british=True, fallback=fb_gb)

    # Signal readiness after models/lexicons are loaded
    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            text = _normalize_pronunciation(req.get("text", ""))
            british = bool(req.get("british", False))
            g2p = g2p_gb if british else g2p_us
            phonemes, _ = g2p(text)
            sys.stdout.write(json.dumps({"phonemes": phonemes}) + "\n")
        except Exception as exc:
            sys.stdout.write(json.dumps({"error": str(exc)}) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
