# Media Tools API — Product Requirements Document

## Overview

Media Tools API is a media processing microservice focused on YouTube transcript extraction and AI-powered summarization. It provides a clean REST API for programmatic access and a polished React frontend for direct use.

## Problem Statement

Developers and content creators need quick access to YouTube transcripts for:
- Content repurposing (blog posts, social media)
- Research and analysis
- Accessibility improvements
- AI training data collection
- Study and note-taking

Existing solutions are either:
- Web-only (no API access)
- Unreliable (break frequently)
- Missing AI summary capabilities
- Poorly documented

## Target Users

1. **Developers** — Need a reliable API for transcript extraction in their apps
2. **Content Creators** — Want to repurpose video content into other formats
3. **Researchers** — Need bulk transcript access for analysis
4. **Students** — Want summaries of educational videos

## Core Features

### Phase 1 (MVP)

1. **YouTube Transcript Extraction**
   - Accept YouTube URL or video ID
   - Extract transcript using yt-dlp
   - Store with metadata (title, channel, duration, word count)
   - Handle errors gracefully (no captions, private videos)

2. **AI Summary Generation**
   - Generate summaries via OpenRouter (multi-model support)
   - Configurable length (short/medium/detailed)
   - Configurable style (bullet/narrative/academic)
   - Extract key points automatically

3. **Background Processing**
   - Async job processing with goroutine worker pool
   - Status tracking (pending → processing → completed → failed)
   - Queue management

4. **API Key Authentication**
   - API key creation and management
   - Per-key rate limiting
   - Secure key hashing

5. **Frontend**
   - Clean landing page with URL input
   - Real-time status polling
   - Transcript display with copy functionality
   - Dark mode support

### Phase 2 (Future)

- Batch processing (multiple URLs at once)
- Webhook notifications on job completion
- User accounts and authentication
- Transcript search (full-text)
- Export formats (PDF, Markdown, SRT)
- Video chapter detection
- Multi-language translation
- Browser extension

## Technical Architecture

- **Backend:** Go with Gin framework
- **Database:** PostgreSQL with golang-migrate
- **Frontend:** React + Vite + TypeScript + Tailwind CSS + Framer Motion
- **AI:** OpenRouter API for LLM access
- **Transcripts:** yt-dlp for extraction
- **Deployment:** Docker + Docker Compose

## Success Metrics

- API response time < 100ms (excluding transcript extraction)
- Transcript extraction success rate > 90%
- 99% uptime for the API
- Clean, educational codebase suitable for learning Go
