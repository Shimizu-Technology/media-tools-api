# Media Tools CLI and agent access

`mta` is a thin client of the same API used by the web and iPhone apps. It submits video URLs or local media files, waits for background transcription, and returns transcript text. The API key decides which account owns the result.

## Install and connect

With Go 1.25.6 or newer:

```bash
go install github.com/Shimizu-Technology/media-tools-api/cmd/mta@latest
```

Create an **account-scoped** key in Media Tools → Developer. Store it in your agent's secret store or shell environment as `MTA_API_KEY`; do not put it in a prompt, source file, or command argument. Set `MTA_API_URL` only when using a different approved API deployment. The default is `https://media-tools-api.onrender.com`.

The repository includes an agent skill at `.agents/skills/media-tools-transcription/SKILL.md`. Install or point your agent to that file and give the agent access only to the intended account key. Revoke the key in the Developer page when access should end.

## Transcribe

```bash
mta transcribe --output json 'https://www.youtube.com/watch?v=VIDEO_ID'
mta transcribe --content-type voice_memo '/path/to/memo.m4a'
```

By default, stdout contains only the completed transcript text. `--output json` emits a stable object with `kind`, `id`, `status`, and, on completion, `transcript_text` and `word_count`. Progress and errors go to stderr. An unsuccessful command exits nonzero.

For a job that outlasts an agent turn:

```bash
mta transcribe --no-wait --output json 'https://www.youtube.com/watch?v=VIDEO_ID'
mta transcribe --resume video:RETURNED_ID --output json
```

Use `audio:RETURNED_ID` to resume a local file upload. `--timeout` defaults to 30 minutes and `--interval` to 5 seconds. A timeout does not cancel the accepted job. Before repeating a submission after a network failure, check the Media Tools library to avoid duplicates.

Local uploads accept MP3, WAV, CAF, M4A, MP4, OGG, FLAC, and WebM, up to the API's 2 GB limit. The file is streamed to the API, which sends audio for AI transcription. Use only recordings authorized for this Media Tools account; client, student, payroll, and other restricted data may need a different approved workspace.
