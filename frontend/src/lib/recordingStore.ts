/**
 * Recordings live on this device until the server has them.
 *
 * While recording, every one-second chunk is written to IndexedDB as it
 * arrives, so a crash, a closed tab, or a dead battery loses at most a second.
 * On stop the chunks become one draft. A draft is deleted only after its
 * upload succeeds. Drafts from the previous version (a single `latest` entry)
 * are still read.
 */
export interface PendingRecording {
  id: string;
  blob: Blob;
  mimeType: string;
  durationSeconds: number;
  createdAt: number;
  /** True when the chunks were rescued after the page ended mid-recording. */
  recovered?: boolean;
}

type StoredChunk = { sessionId: string; seq: number; blob: Blob; mimeType: string; startedAt: number; at: number };

// A session still receiving chunks may be recording in another tab.
const LIVE_SESSION_MS = 15_000;

const DB_NAME = 'media-tools-audio';
const DB_VERSION = 2;
const DRAFTS = 'pending-recordings';
const CHUNKS = 'recording-chunks';
const LEGACY_KEY = 'latest';

function available(): boolean {
  return typeof indexedDB !== 'undefined';
}

let dbPromise: Promise<IDBDatabase> | null = null;

function open(): Promise<IDBDatabase> {
  if (!dbPromise) {
    dbPromise = new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, DB_VERSION);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(DRAFTS)) db.createObjectStore(DRAFTS);
        if (!db.objectStoreNames.contains(CHUNKS)) db.createObjectStore(CHUNKS);
      };
      request.onsuccess = () => {
        const db = request.result;
        // Another tab upgrading the schema must not be blocked by this one.
        db.onversionchange = () => { db.close(); dbPromise = null; };
        resolve(db);
      };
      request.onerror = () => { dbPromise = null; reject(request.error); };
      request.onblocked = () => { dbPromise = null; reject(new Error('Recording storage is busy in another tab.')); };
    });
  }
  return dbPromise;
}

function done(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error ?? new Error('Recording storage was interrupted.'));
  });
}

function requestValue<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function chunkKey(sessionId: string, seq: number): string {
  return `${sessionId}:${String(seq).padStart(8, '0')}`;
}

export async function appendRecordingChunk(chunk: StoredChunk): Promise<void> {
  if (!available()) return;
  const db = await open();
  const tx = db.transaction(CHUNKS, 'readwrite');
  tx.objectStore(CHUNKS).put(chunk, chunkKey(chunk.sessionId, chunk.seq));
  await done(tx);
}

async function deleteChunks(db: IDBDatabase, sessionId: string): Promise<void> {
  const tx = db.transaction(CHUNKS, 'readwrite');
  tx.objectStore(CHUNKS).delete(IDBKeyRange.bound(`${sessionId}:`, `${sessionId}:￿`));
  await done(tx);
}

/** The finished recording becomes a draft; its chunks are then dropped. */
export async function saveRecordingDraft(recording: PendingRecording): Promise<void> {
  if (!available()) return;
  const db = await open();
  const tx = db.transaction(DRAFTS, 'readwrite');
  tx.objectStore(DRAFTS).put(recording, recording.id);
  await done(tx);
  await deleteChunks(db, recording.id);
}

/** Turn chunks left by a page that ended mid-recording into drafts. */
export async function recoverInterruptedRecordings(activeSessionId?: string): Promise<number> {
  let recovered = 0;
  if (!available()) return 0;
  const db = await open();
  const tx = db.transaction(CHUNKS, 'readonly');
  const chunks = await requestValue(tx.objectStore(CHUNKS).getAll() as IDBRequest<StoredChunk[]>);
  const sessions = new Map<string, StoredChunk[]>();
  for (const chunk of chunks) {
    if (chunk.sessionId === activeSessionId) continue;
    sessions.set(chunk.sessionId, [...(sessions.get(chunk.sessionId) ?? []), chunk]);
  }
  for (const [sessionId, parts] of sessions) {
    parts.sort((a, b) => a.seq - b.seq);
    if (Date.now() - (parts[parts.length - 1].at ?? 0) < LIVE_SESSION_MS) continue;
    const mimeType = parts[0].mimeType;
    await saveRecordingDraft({
      id: sessionId,
      blob: new Blob(parts.map((part) => part.blob), { type: mimeType }),
      mimeType,
      // One chunk per second of recording.
      durationSeconds: parts.length,
      createdAt: parts[0].startedAt,
      recovered: true,
    });
    recovered += 1;
  }
  return recovered;
}

export async function listRecordingDrafts(): Promise<PendingRecording[]> {
  if (!available()) return [];
  const db = await open();
  const tx = db.transaction(DRAFTS, 'readonly');
  const store = tx.objectStore(DRAFTS);
  const [keys, values] = await Promise.all([
    requestValue(store.getAllKeys()),
    requestValue(store.getAll() as IDBRequest<Array<Partial<PendingRecording> & { blob: Blob }>>),
  ]);
  return values
    .map((value, index) => ({
      id: value.id ?? String(keys[index] ?? LEGACY_KEY),
      blob: value.blob,
      mimeType: value.mimeType || value.blob?.type || 'audio/webm',
      durationSeconds: value.durationSeconds ?? 0,
      createdAt: value.createdAt ?? Date.now(),
      recovered: value.recovered,
    }))
    .filter((draft) => draft.blob instanceof Blob && draft.blob.size > 0)
    .sort((a, b) => b.createdAt - a.createdAt);
}

export async function deleteRecordingDraft(id: string): Promise<void> {
  if (!available()) return;
  const db = await open();
  const tx = db.transaction(DRAFTS, 'readwrite');
  tx.objectStore(DRAFTS).delete(id);
  await done(tx);
}
