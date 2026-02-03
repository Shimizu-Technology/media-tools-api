# Future Improvements

Ideas and enhancements to consider for future development.

---

## Access Control Options

Currently, API key creation requires an admin key. Consider these alternatives for more open access:

### Option A: Public Key Creation with Aggressive Rate Limits
- Remove admin key requirement
- Add captcha to prevent bots
- Strict per-key rate limits (e.g., 10 transcriptions/day)
- Risk: Potential cost abuse

### Option B: Shared Demo Key
- Pre-create a "demo" API key with low quotas
- Embed in app or share publicly
- Everyone shares the same rate limit pool
- Good for: Demos, trials

### Option C: User Accounts with Quotas
- Email/password registration
- Each account gets X free transcriptions/month
- Requires: Email verification, password reset flow
- More infrastructure but better accountability

---

## Other Ideas

- [ ] Batch audio uploads
- [ ] Longer audio file support (chunked uploads)
- [ ] Speaker diarization (who said what)
- [ ] Real-time transcription via WebSocket
- [ ] Export to Google Docs / Notion
- [ ] Mobile app (React Native or PWA enhancements)
- [ ] Usage dashboard / analytics
- [ ] Stripe integration for paid tiers

---

*Add your ideas here as they come up!*
