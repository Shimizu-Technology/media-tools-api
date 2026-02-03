# YouTube Extraction Fix Guide

> **Last Updated:** February 2026  
> **Status:** Working with residential proxy + `android_vr` client

This document explains how to fix YouTube extraction issues on cloud hosting platforms like Render, Railway, AWS, etc.

## The Problem

YouTube has implemented aggressive anti-bot measures that block video extraction from cloud/datacenter IPs:

1. **Datacenter IP Blocking**: YouTube blocks all major cloud provider IP ranges (AWS, GCP, Render, Railway, Heroku, etc.)
2. **Bot Detection**: Even with valid requests, YouTube returns "Sign in to confirm you're not a bot"
3. **PO Token Requirements**: Some yt-dlp clients now require "Proof of Origin" tokens
4. **SABR Streaming**: YouTube forces certain clients to use SABR streaming which breaks downloads

## The Solution

Two things are required:

### 1. Residential Proxy (Required)

YouTube only allows requests from residential IP addresses. You need a rotating residential proxy service.

**Recommended: [Webshare.io](https://www.webshare.io/)**
- Cost: ~$5-10/month for rotating residential proxies
- Setup:
  1. Sign up at https://www.webshare.io/
  2. Purchase "Rotating Residential" proxies
  3. Get your proxy credentials from the dashboard
  4. Format: `http://username:password@p.webshare.io:80`

### 2. Use `android_vr` Client (Required)

Not all yt-dlp clients work. Here's the current status (February 2026):

| Client | PO Token Required | Works with Proxy | Notes |
|--------|------------------|------------------|-------|
| `android_vr` | **No** | **Yes** | Recommended |
| `tv` | No | Yes | May have DRM issues if overused |
| `ios` | Yes (GVS) | No | Requires PO Token we can't provide |
| `web` | Yes (GVS/Subs) | No | Only SABR formats available |
| `mweb` | Yes (GVS) | No | Requires PO Token |

**Use `android_vr`** - it doesn't require a PO Token and works well with residential proxies.

## Implementation

### Environment Variable

Add to your environment (Render, Railway, .env, etc.):

```bash
YOUTUBE_PROXY=http://username:password@p.webshare.io:80
```

### Go Implementation (media-tools-api)

```go
// In config/config.go - add YouTubeProxy field
type Config struct {
    // ... other fields
    YouTubeProxy string
}

func Load() (*Config, error) {
    return &Config{
        // ... other fields
        YouTubeProxy: os.Getenv("YOUTUBE_PROXY"),
    }, nil
}

// In your extractor, build yt-dlp args like this:
func buildYtDlpArgs(proxyURL string) []string {
    args := []string{
        "--js-runtimes", "node",              // Required for YouTube extraction
        "--remote-components", "ejs:github",  // Download JS challenge solver
    }
    if proxyURL != "" {
        args = append(args, "--proxy", proxyURL)
        // Use android_vr client - doesn't require PO Token
        args = append(args, "--extractor-args", "youtube:player_client=android_vr")
    }
    return args
}
```

### Python Implementation (recipe-api)

```python
import os
import asyncio

YOUTUBE_PROXY = os.getenv("YOUTUBE_PROXY", "")

async def download_with_ytdlp(url: str, output_path: str):
    args = [
        "yt-dlp",
        "--js-runtimes", "node",
        "--remote-components", "ejs:github",
    ]
    
    if YOUTUBE_PROXY:
        args.extend([
            "--proxy", YOUTUBE_PROXY,
            "--extractor-args", "youtube:player_client=android_vr",
        ])
    
    args.extend([
        "--extract-audio",
        "--audio-format", "mp3",
        "--output", output_path,
        url,
    ])
    
    process = await asyncio.create_subprocess_exec(
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await process.communicate()
    
    if process.returncode != 0:
        raise Exception(f"yt-dlp failed: {stderr.decode()}")
    
    return output_path
```

### Docker Requirements

Your Docker image must have Node.js installed for yt-dlp's JavaScript runtime:

```dockerfile
# In your runtime stage
RUN apk add --no-cache nodejs
# Or for Debian/Ubuntu:
# RUN apt-get update && apt-get install -y nodejs
```

Also pin yt-dlp to a known working version:

```dockerfile
RUN pip3 install yt-dlp==2025.11.12
```

## Key yt-dlp Arguments

| Argument | Purpose |
|----------|---------|
| `--js-runtimes node` | Use Node.js for JavaScript challenges |
| `--remote-components ejs:github` | Download JS solver from GitHub |
| `--proxy URL` | Route requests through residential proxy |
| `--extractor-args "youtube:player_client=android_vr"` | Use VR client (no PO Token needed) |

## Troubleshooting

### "Sign in to confirm you're not a bot"
- Your proxy isn't working or isn't residential
- Check proxy credentials
- Verify proxy is "rotating residential" not "datacenter"

### "No supported JavaScript runtime"
- Install Node.js in your Docker image
- Add `--js-runtimes node` to yt-dlp commands

### "ios client requires GVS PO Token"
- Switch to `android_vr` client
- Don't use `ios`, `web`, or `mweb` clients

### "Requested format is not available"
- The client you're using doesn't support the format
- `android_vr` should provide audio formats

### "YouTube is forcing SABR streaming"
- Switch from `tv` or `web` client to `android_vr`
- SABR streaming breaks partial downloads

## Cost Estimate

- **Webshare Rotating Residential**: ~$5-10/month for light usage
- This is the minimum viable solution for cloud-hosted YouTube extraction

## References

- [yt-dlp PO Token Guide](https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide)
- [yt-dlp YouTube Extractor Wiki](https://github.com/yt-dlp/yt-dlp/wiki/Extractors#youtube)
- [yt-dlp EJS (JavaScript) Wiki](https://github.com/yt-dlp/yt-dlp/wiki/EJS)

## Summary

1. Get a **rotating residential proxy** (Webshare ~$5-10/mo)
2. Set `YOUTUBE_PROXY` environment variable
3. Use `--proxy` and `--extractor-args "youtube:player_client=android_vr"`
4. Ensure Node.js is installed for `--js-runtimes node`
5. Pin yt-dlp version to avoid breaking changes
