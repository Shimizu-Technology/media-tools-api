#!/usr/bin/env python3
"""Check that the website and signed iOS app can share Media Tools passkeys."""

import json
import plistlib
import tomllib
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

    # netlify.toml holds the SPA fallback, because _redirects runs first and a
    # catch-all there would swallow the signed API proxy.
    netlify = tomllib.loads((public.parents[1] / "netlify.toml").read_text())
    rules = netlify.get("redirects", [])
    fallback = [rule for rule in rules if rule.get("from") == "/*"]
    assert len(fallback) == 1 and fallback[0].get("to") == "/index.html" and fallback[0].get("status") == 200, (
        "netlify.toml must hold the SPA fallback"
    )
    assert not fallback[0].get("force", False), (
        "SPA fallback must remain unforced so Netlify serves the AASA file"
    )

    # Netlify applies the first matching rule, top to bottom. Below the fallback,
    # the proxy would never run and /api/* would be answered with index.html.
    proxy = [index for index, rule in enumerate(rules) if rule.get("from") == "/api/*"]
    assert len(proxy) == 1 and proxy[0] < rules.index(fallback[0]), (
        "netlify.toml must place exactly one /api/* proxy before the SPA fallback"
    )

    redirects = (public / "_redirects").read_text().splitlines()
    assert not any(line.split()[:1] == ["/*"] for line in redirects), (
        "A catch-all in _redirects would run before the signed API proxy and the AASA file"
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
