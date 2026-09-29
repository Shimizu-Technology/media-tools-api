#!/usr/bin/env python3
"""Check that the website and signed iOS app can share Media Tools passkeys."""

import json
import plistlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOMAIN = "media.shimizu-technology.com"
APP_ID = "4T358A5S74.com.ShimizuTechnology.MediaTools"
ASSOCIATION_PATH = Path(".well-known/apple-app-site-association")


def check_public_files(public: Path) -> None:
    association = json.loads((public / ASSOCIATION_PATH).read_text())
    assert association == {"webcredentials": {"apps": [APP_ID]}}, (
        "AASA must contain the verified app identifier under webcredentials"
    )

    redirects = (public / "_redirects").read_text().splitlines()
    assert "/*    /index.html   200" in redirects, (
        "SPA fallback must remain unforced so Netlify serves the AASA file"
    )
    assert not any(
        line.startswith("/.well-known/apple-app-site-association ") for line in redirects
    ), "Netlify should serve the AASA file directly"

    headers = (public / "_headers").read_text()
    assert "/.well-known/apple-app-site-association\n  Content-Type: application/json" in headers


def main() -> None:
    entitlements = plistlib.loads(
        (ROOT / "ios/MediaTools/MediaTools/MediaTools.entitlements").read_bytes()
    )
    assert entitlements["com.apple.developer.associated-domains"] == [
        f"webcredentials:{DOMAIN}"
    ], "The iOS app must request the passkey domain"

    check_public_files(ROOT / "frontend/public")
    check_public_files(ROOT / "frontend/dist")
    print("Passkey domain association files and iOS entitlement are consistent")


if __name__ == "__main__":
    main()
