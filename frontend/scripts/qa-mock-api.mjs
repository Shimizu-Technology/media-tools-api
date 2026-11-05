#!/usr/bin/env node
/**
 * A local stand-in for the API, for browser QA of the web app without a backend
 * or any real data. Development only; nothing imports it.
 *
 *   node scripts/qa-mock-api.mjs                     # listens on 18975
 *   MTA_API_PROXY_TARGET=http://localhost:18975 npx vite --port 5975 --strictPort
 *
 * POST /__scenario with {"name": "normal" | "empty" | "worst" | "legacy" | "down"}
 * changes the data. `legacy` omits the new optional fields, as the server does
 * until it deploys. Waveform fixtures are measured from a generated WAV.
 */
import { createServer } from 'node:http';

const PORT = Number(process.env.MOCK_PORT || 18975);
const DAY = 86_400_000;
const SAMPLE_RATE = 8000;
const SECONDS = 96;

// Speech-like bursts and pauses: the audio the player actually plays.
const samples = new Int16Array(SAMPLE_RATE * SECONDS);
for (let index = 0; index < samples.length; index += 1) {
  const t = index / SAMPLE_RATE;
  const phrase = 0.08 + 0.92 * Math.abs(Math.sin(t * 0.21) * Math.cos(t * 0.57));
  const syllable = 0.5 + 0.5 * Math.abs(Math.sin(t * 2.3));
  samples[index] = Math.round(11000 * phrase * syllable * Math.sin(2 * Math.PI * 180 * t));
}
function wav() {
  const header = Buffer.alloc(44);
  const size = samples.length * 2;
  header.write('RIFF', 0); header.writeUInt32LE(36 + size, 4); header.write('WAVEfmt ', 8);
  header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(SAMPLE_RATE, 24); header.writeUInt32LE(SAMPLE_RATE * 2, 28);
  header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34); header.write('data', 36); header.writeUInt32LE(size, 40);
  return Buffer.concat([header, Buffer.from(samples.buffer)]);
}
const WAV = wav();
function peaks(count, offset = 0) {
  const out = [];
  const size = Math.floor(samples.length / count);
  for (let bar = 0; bar < count; bar += 1) {
    let loudest = 0;
    const start = (bar * size + offset * SAMPLE_RATE) % (samples.length - size);
    for (let index = start; index < start + size; index += 1) loudest = Math.max(loudest, Math.abs(samples[index]));
    out.push(Math.round((loudest / 14000) * 100));
  }
  return out.map((value) => Math.min(100, value));
}

const ago = (ms) => new Date(Date.now() - ms).toISOString();
const COLLECTIONS = [
  { id: 'col-baby', name: 'Baby', color: 'coral', item_count: 2 },
  { id: 'col-work', name: 'Work', color: 'teal', item_count: 2 },
  { id: 'col-ideas', name: 'Ideas', color: 'violet', item_count: 1 },
  { id: 'col-calls', name: 'Calls', color: 'amber', item_count: 0 },
  { id: 'col-odd', name: 'Unknown color', color: 'lime', item_count: 0 },
].map((collection) => ({ description: '', created_at: ago(40 * DAY), updated_at: ago(DAY), ...collection }));
const tag = (index) => { const { id, name, color } = COLLECTIONS[index]; return { id, name, color }; };

function base(overrides) {
  return { subtitle: '', status: 'completed', word_count: 900, duration: 96, page_count: 0, summary_status: 'completed', favorite: false, archived: false, tags: [], collections: [], ...overrides };
}
const NORMAL = [
  base({ id: 'rec-busy', item_type: 'audio', title: 'Recording, Nov 5 at 7:57 AM', status: 'processing', summary_status: 'none', word_count: 0, duration: 0, created_at: ago(30 * 60_000) }),
  base({ id: 'rec-baby', item_type: 'audio', title: 'Hafa Baby updates', excerpt: 'What changed this week, what is still open, and what to test before the next round.', waveform: peaks(32, 0), collections: [tag(0)], created_at: ago(DAY) }),
  base({ id: 'rec-app', item_type: 'audio', title: 'Baby Shimizu App', excerpt: 'Ideas for the first version and what it needs to do on day one.', waveform: peaks(32, 17), duration: 320, collections: [tag(0)], favorite: true, created_at: ago(17 * DAY) }),
  base({ id: 'rec-plan', item_type: 'audio', title: 'Planning call', excerpt: 'Launch moves to the 18th so QA can run a full week. Split QA between two people.', waveform: peaks(32, 31), duration: 2530, collections: [tag(1)], created_at: ago(19 * DAY) }),
  base({ id: 'vid-1', item_type: 'youtube', title: 'How to read a contract', subtitle: 'Law School', excerpt: 'The clauses to read first, and the ones people usually skip.', duration: 842, collections: [tag(2)], created_at: ago(24 * DAY) }),
  base({ id: 'pdf-1', item_type: 'pdf', title: 'Lease agreement.pdf', excerpt: 'Term, renewal dates and who pays for repairs.', duration: 0, page_count: 18, collections: [tag(1)], created_at: ago(27 * DAY) }),
  base({ id: 'rec-plain', item_type: 'audio', title: 'Quick note', duration: 41, created_at: ago(30 * DAY) }),
  base({ id: 'rec-failed', item_type: 'audio', title: 'Aug 26 recording', status: 'failed', duration: 5352, summary_status: 'none', created_at: ago(2 * DAY) }),
  base({ id: 'vid-failed', item_type: 'youtube', title: 'A video with no captions', status: 'failed', duration: 0, summary_status: 'none', created_at: ago(3 * DAY) }),
  base({ id: 'rec-old-failed', item_type: 'audio', title: 'Old failed recording', status: 'failed', duration: 60, summary_status: 'none', created_at: ago(40 * DAY) }),
];
const LONG = 'Weekly leadership sync with the Guam Department of Education regarding the 2026-2027 enrollment projections, Chamorro language immersion staffing, and the renegotiated transportation contract for Agana Heights';
const WORST = [
  base({ id: 'rec-baby', item_type: 'audio', title: LONG, excerpt: `${'Enrollment rises in the northern villages while immersion staffing stays flat, so the board asked for a revised plan before the next budget hearing and a phased '.slice(0, 197)}...`, waveform: peaks(32, 3), duration: 35999, collections: [{ id: 'col-long', name: 'Hafa Adai Community Partnerships and Grants Committee, Fiscal Year 2027', color: 'rose' }], favorite: true, created_at: ago(DAY) }),
  base({ id: 'a', item_type: 'audio', title: 'X', duration: 1, waveform: Array.from({ length: 32 }, () => 0), created_at: ago(2 * DAY) }),
  base({ id: 'pdf-1', item_type: 'pdf', title: 'unbroken_filename_with_no_spaces_at_all_quarterly_financial_statement_final_final_v12.pdf', page_count: 12480, created_at: ago(3 * DAY) }),
  base({ id: 'vid-1', item_type: 'youtube', title: '日本語のタイトルとても長い録音の文字起こしテスト、会議の議事録と決定事項のまとめ', subtitle: 'Unknown channel', excerpt: 'Pågan Håfa Adai: un tiempo para i famagu’on, yan i manåmko’.', duration: 842, created_at: ago(370 * DAY) }),
  base({ id: 'rec-failed', item_type: 'audio', title: LONG, status: 'failed', duration: 5352, summary_status: 'none', created_at: ago(DAY) }),
  base({ id: 'rec-busy', item_type: 'audio', title: LONG, status: 'processing', summary_status: 'none', waveform: peaks(32, 9), created_at: ago(1000) }),
];
const LEGACY_FIELDS = ['excerpt', 'waveform', 'collections'];

let scenario = 'normal';
function items() {
  if (scenario === 'empty') return [];
  if (scenario === 'worst') return WORST;
  if (scenario === 'legacy') return NORMAL.map((item) => Object.fromEntries(Object.entries(item).filter(([key]) => !LEGACY_FIELDS.includes(key))));
  return NORMAL;
}
function collections() {
  if (scenario === 'empty') return [];
  if (scenario === 'legacy') return COLLECTIONS.map(({ color: _color, ...rest }) => rest);
  if (scenario === 'worst') return [...COLLECTIONS, { ...COLLECTIONS[0], id: 'col-long', name: 'Hafa Adai Community Partnerships and Grants Committee, Fiscal Year 2027', color: 'rose', item_count: 123456 }];
  return COLLECTIONS;
}

const SEGMENTS = ['Okay, quick update on where everything stands this week.', 'The first thing is the sign-in, which is working now.', 'What is still open is the share screen and how it looks.', 'Before the next round I want to test the Action Button again.', 'Everything else moved to the list we keep for after launch.', 'Let me know if anything here looks wrong to you.'];
function segments(type, id) {
  if (type === 'pdf') return [1, 2].map((page) => ({ id: `p${page}`, item_type: 'pdf', item_id: id, ordinal: page, page_number: page, text: `Page ${page} of the lease. The tenant pays for ordinary repairs.`, created_at: ago(DAY) }));
  return SEGMENTS.map((text, index) => ({ id: `s${index}`, item_type: type, item_id: id, ordinal: index, start_ms: index * 16000, end_ms: (index + 1) * 16000 - 1000, text, created_at: ago(DAY) }));
}
function audioDetail(id) {
  const item = items().find((entry) => entry.id === id) ?? NORMAL[1];
  const text = SEGMENTS.join(' ');
  return {
    id, filename: 'a.m4a', original_name: item.title, audio_s3_status: 'stored', duration: 96, language: 'en', transcript_text: text, formatted_transcript_text: SEGMENTS.join('\n\n'),
    formatting_status: 'completed', word_count: 60, status: item.status, error_message: item.status === 'failed' ? 'Transcription failed. The recording is saved.' : undefined,
    content_type: 'voice_memo', summary_text: 'What changed this week, what is still open, and what to test before the next round.',
    key_points: ['Sign-in now works without a password prompt.', 'The share screen still needs a design pass.', 'Test the Action Button again next round.'], action_items: ['Send the revised list.'], decisions: [],
    summary_length: 'medium', summary_status: item.status === 'completed' ? 'completed' : 'none', created_at: item.created_at, updated_at: item.created_at,
    ...(scenario === 'legacy' || id === 'rec-plain' ? {} : { waveform: peaks(200, 0) }),
  };
}

const USER = { id: 'qa-user', email: 'qa@example.com', name: 'QA Person' };
function route(method, path, query) {
  const list = /^\/api\/v1\/library\/items$/.test(path);
  // Uploads skip S3: presign refuses, and the API fallback accepts the file.
  if (method === 'POST' && path === '/api/v1/audio/transcribe') return audioDetail('rec-baby');
  if (path === '/api/v1/auth/web/session/status') return { authenticated: true, user_id: USER.id };
  if (path === '/api/v1/health') return { status: 'ok', features: {}, password_auth_enabled: true, signup_enabled: true };
  if (path === '/api/v1/auth/me') return USER;
  if (path === '/api/v1/auth/usage') return { month: '2026-11', transcription_seconds: 2160, transcription_limit_seconds: 18000, ai_requests: 41, ai_request_limit: 500, exempt: false };
  if (path === '/api/v1/auth/password') return { configured: true };
  if (path === '/api/v1/auth/password/status') return { configured: true };
  if (path === '/api/v1/auth/passkeys') return { count: 1 };
  if (path === '/api/v1/auth/sessions') return { sessions: [] };
  if (path === '/api/v1/account/processing-preferences') return { automatic_summaries: true };
  if (list) {
    let data = items().filter((item) => !item.archived);
    const status = query.get('status');
    if (status === 'active') data = data.filter((item) => item.status === 'pending' || item.status === 'processing');
    else if (status) data = data.filter((item) => item.status === status);
    const type = query.get('type'); if (type) data = data.filter((item) => item.item_type === type);
    const search = query.get('search')?.toLowerCase(); if (search) data = data.filter((item) => item.title.toLowerCase().includes(search));
    if (query.get('favorite') === 'true') data = data.filter((item) => item.favorite);
    if (query.get('sort_dir') === 'asc') data = [...data].reverse();
    const perPage = Number(query.get('per_page') || 30);
    return { data: data.slice(0, perPage), total_items: scenario === 'worst' && !status ? 123456 : data.length, total_pages: 1, page: 1, per_page: perPage };
  }
  if (path === '/api/v1/library/stats') { const all = items(); return { total: all.length, pending: 0, processing: 1, completed: all.length - 2, failed: all.filter((item) => item.status === 'failed').length, videos: 1, audio: 5, pdfs: 1 }; }
  if (/\/preferences$/.test(path)) return { favorite: false, archived: false, tags: [] };
  if (path === '/api/v1/collections' && method === 'POST') return { ...COLLECTIONS[3], id: 'col-new', name: 'New one', item_count: 0 };
  if (path === '/api/v1/collections') return collections();
  let match = path.match(/^\/api\/v1\/collections\/([^/]+)$/);
  if (match) {
    const collection = collections().find((entry) => entry.id === match[1]);
    if (!collection) return { status: 404, body: { error: 'not_found', message: 'That collection could not be found.', code: 404 } };
    const inside = items().filter((item) => item.collections?.some((entry) => entry.id === collection.id));
    return { ...collection, items: inside.map((item, index) => ({ id: `ci-${item.id}`, collection_id: collection.id, item_type: item.item_type === 'youtube' ? 'transcript' : item.item_type, item_id: item.id, item_title: item.title, item_status: item.status, position: index, added_at: item.created_at })) };
  }
  match = path.match(/^\/api\/v1\/audio\/transcriptions\/([^/]+)$/);
  if (match) return audioDetail(match[1]);
  if (/\/audio$/.test(path)) return { url: '/api/qa-audio.wav' };
  match = path.match(/^\/api\/v1\/transcripts\/([^/]+)$/);
  if (match) return { id: match[1], youtube_url: 'https://www.youtube.com/watch?v=x', youtube_id: 'x', title: 'How to read a contract', channel_name: 'Law School', duration: 842, language: 'en', transcript_text: SEGMENTS.join(' '), word_count: 60, status: 'completed', created_at: ago(DAY), updated_at: ago(DAY) };
  if (/\/transcripts\/[^/]+\/summaries$/.test(path) || /\/summaries$/.test(path)) return [];
  match = path.match(/^\/api\/v1\/pdf\/extractions\/([^/]+)$|^\/api\/v1\/pdfs\/([^/]+)$/);
  if (match) return { id: match[1] ?? match[2], original_name: 'Lease agreement.pdf', page_count: 2, text_content: 'The tenant pays for ordinary repairs.', status: 'completed', created_at: ago(DAY) };
  match = path.match(/segments/);
  if (match) { const parts = path.split('/'); const id = parts.at(-2); const type = path.includes('pdf') ? 'pdf' : path.includes('audio') ? 'audio' : 'transcript'; return segments(type, id); }
  if (/\/chat/.test(path)) return { session: { id: 'c' }, messages: [] };
  return null;
}

createServer((request, response) => {
  const url = new URL(request.url, 'http://localhost');
  const send = (status, body) => { response.writeHead(status, { 'Content-Type': 'application/json' }); response.end(JSON.stringify(body)); };
  if (url.pathname === '/__scenario') {
    let raw = '';
    request.on('data', (chunk) => { raw += chunk; });
    request.on('end', () => { scenario = JSON.parse(raw).name; send(200, { scenario }); });
    return;
  }
  if (url.pathname === '/api/qa-audio.wav') {
    const range = /bytes=(\d+)-(\d*)/.exec(request.headers.range ?? '');
    const start = range ? Number(range[1]) : 0;
    const end = range && range[2] ? Number(range[2]) : WAV.length - 1;
    response.writeHead(range ? 206 : 200, { 'Content-Type': 'audio/wav', 'Accept-Ranges': 'bytes', 'Content-Length': end - start + 1, ...(range ? { 'Content-Range': `bytes ${start}-${end}/${WAV.length}` } : {}) });
    response.end(WAV.subarray(start, end + 1));
    return;
  }
  const session = url.pathname.startsWith('/api/v1/auth') || url.pathname === '/api/v1/health';
  if (scenario === 'down' && !session) return send(503, { error: 'unavailable', message: 'The server is having trouble.', code: 503 });
  const result = route(request.method, url.pathname, url.searchParams);
  if (result === null) { console.log('MISS', request.method, url.pathname); return send(404, { error: 'not_found', message: 'Not in the mock.', code: 404 }); }
  if (result.status && result.body) return send(result.status, result.body);
  return send(200, result);
}).listen(PORT, '127.0.0.1', () => console.log(`mock API on ${PORT}`));
