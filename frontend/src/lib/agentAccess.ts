import type { AgentActivity, APIKey } from './api';

export type KeyScope = 'library:read' | 'library:write' | 'library:delete' | 'capture:upload';

export interface ScopeOption {
  id: KeyScope;
  label: string;
  description: string;
}

// Order matches the server's canonical order, so a created key lists its
// scopes the same way here as it does in the API.
export const SCOPE_OPTIONS: ScopeOption[] = [
  { id: 'library:read', label: 'Read library', description: 'List, search, and read transcripts, summaries, and chats.' },
  { id: 'library:write', label: 'Organize and create', description: 'Rename, tag, file in collections, retry, summarize, chat, and add new items.' },
  { id: 'library:delete', label: 'Delete', description: 'Permanently delete items and collections.' },
  { id: 'capture:upload', label: 'Upload recordings only', description: 'Send a new recording for transcription. Cannot read or change anything.' },
];

export interface ScopePreset {
  id: string;
  label: string;
  scopes: KeyScope[];
}

export const SCOPE_PRESETS: ScopePreset[] = [
  { id: 'read', label: 'Read only', scopes: ['library:read'] },
  { id: 'organize', label: 'Read and organize', scopes: ['library:read', 'library:write'] },
  { id: 'upload', label: 'Upload only', scopes: ['capture:upload'] },
];

export const DEFAULT_AGENT_SCOPES: KeyScope[] = ['library:read', 'library:write'];

export function isScopedKey(key: Pick<APIKey, 'scopes'>): boolean {
  return Array.isArray(key.scopes) && key.scopes.length > 0;
}

export function scopeLabel(scope: string): string {
  return SCOPE_OPTIONS.find((option) => option.id === scope)?.label ?? scope;
}

// Toggle one scope, keeping the server's canonical order.
export function toggleScope(current: KeyScope[], scope: KeyScope): KeyScope[] {
  const next = current.includes(scope) ? current.filter((entry) => entry !== scope) : [...current, scope];
  return SCOPE_OPTIONS.map((option) => option.id).filter((id) => next.includes(id));
}

const ROUTE_ACTIONS: Array<{ method: string; route: RegExp; text: string }> = [
  { method: 'PATCH', route: /\/audio\/transcriptions\/:id$/, text: 'Renamed a recording' },
  { method: 'DELETE', route: /\/audio\/transcriptions\/:id$/, text: 'Deleted a recording' },
  { method: 'POST', route: /\/audio\/transcriptions\/:id\/retry$/, text: 'Retried a recording' },
  { method: 'POST', route: /\/audio\/transcriptions\/:id\/cancel$/, text: 'Canceled a recording' },
  { method: 'POST', route: /\/audio\/transcriptions\/:id\/summarize$/, text: 'Summarized a recording' },
  { method: 'POST', route: /\/audio\/transcriptions\/:id\/format$/, text: 'Formatted a transcript' },
  { method: 'POST', route: /\/audio\/uploads\/presign$/, text: 'Started a recording upload' },
  { method: 'POST', route: /\/audio\/uploads\/complete$/, text: 'Uploaded a recording' },
  { method: 'POST', route: /\/audio\/transcribe$/, text: 'Uploaded a recording' },
  { method: 'POST', route: /\/chat$/, text: 'Sent a chat message' },
  { method: 'POST', route: /\/summaries$/, text: 'Requested a summary' },
  { method: 'POST', route: /\/transcripts(\/batch)?$/, text: 'Added a video' },
  { method: 'DELETE', route: /\/transcripts\/:id$/, text: 'Deleted a video' },
  { method: 'POST', route: /\/pdf\/extract$/, text: 'Added a PDF' },
  { method: 'DELETE', route: /\/pdf\/extractions\/:id$/, text: 'Deleted a PDF' },
  { method: 'POST', route: /\/collections$/, text: 'Created a collection' },
  { method: 'PATCH', route: /\/collections\/:id$/, text: 'Edited a collection' },
  { method: 'DELETE', route: /\/collections\/:id$/, text: 'Deleted a collection' },
  { method: 'POST', route: /\/collections\/:id\/items$/, text: 'Filed items in a collection' },
  { method: 'DELETE', route: /\/collections\/:id\/items\/:itemId$/, text: 'Removed an item from a collection' },
  { method: 'PATCH', route: /\/library\/items\/:type\/:id\/preferences$/, text: 'Changed tags, star, or archive' },
];

// describeActivity turns a stored method and route into a sentence. A request
// the server refused is described as refused, whatever it tried to do.
export function describeActivity(row: Pick<AgentActivity, 'method' | 'route' | 'status_code'>): string {
  const match = ROUTE_ACTIONS.find((action) => action.method === row.method && action.route.test(row.route));
  if (!match) {
    const raw = `${row.method} ${row.route.replace('/api/v1', '')}`;
    if (row.status_code === 403) return `Blocked: ${raw}`;
    return row.status_code >= 400 ? `Failed: ${raw}` : raw;
  }
  const sentence = `${match.text.charAt(0).toLowerCase()}${match.text.slice(1)}`;
  if (row.status_code === 403) return `Blocked: ${sentence}`;
  if (row.status_code >= 400) return `Failed: ${sentence}`;
  return match.text;
}

export function activityItemLabel(row: Pick<AgentActivity, 'item_type' | 'item_id'>): string {
  if (!row.item_id) return '';
  return `${row.item_type || 'item'} ${row.item_id.slice(0, 8)}`;
}
