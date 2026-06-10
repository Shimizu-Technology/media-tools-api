/**
 * API client for the Media Tools API.
 * 
 * In development, Vite proxies /api requests to localhost:8080.
 * In production, VITE_API_URL points to the Render backend.
 */
import { getAuthHeadersAsync, getAuthUploadHeadersAsync } from './apiAuth';

const API_BASE = import.meta.env.VITE_API_URL
  ? `${import.meta.env.VITE_API_URL}/api/v1`
  : '/api/v1';

// ── Types ──

export interface Transcript {
  id: string;
  youtube_url: string;
  youtube_id: string;
  title: string;
  channel_name: string;
  duration: number;
  language: string;
  transcript_text: string;
  word_count: number;
  status: 'pending' | 'processing' | 'completed' | 'failed';
  error_message?: string;
  created_at: string;
  updated_at: string;
}

export interface Summary {
  id: string;
  transcript_id: string;
  model_used: string;
  prompt_used: string;
  summary_text: string;
  key_points: string[];
  length: string;
  style: string;
  created_at: string;
}

export type ChatItemType = 'transcript' | 'audio' | 'pdf' | 'collection';

export interface ChatSession {
  id: string;
  transcript_id?: string;
  item_type: ChatItemType;
  item_id: string;
  api_key_id?: string;
  created_at: string;
  updated_at: string;
}

export interface ChatMessage {
  id: string;
  session_id: string;
  role: 'user' | 'assistant';
  content: string;
  model_used?: string;
  created_at: string;
}

export interface ChatResponse {
  session: ChatSession;
  messages: ChatMessage[];
}

export interface APIKey {
  id: string;
  key_prefix: string;
  name: string;
  active: boolean;
  rate_limit: number;
  created_at: string;
  last_used_at?: string;
  raw_key?: string;
}

export interface PaginatedResponse<T> {
  data: T[];
  page: number;
  per_page: number;
  total_items: number;
  total_pages: number;
}

export interface HealthResponse {
  status: string;
  version: string;
  database: string;
  workers: number;
}

/**
 * Standard API error response from the backend.
 * All API endpoints return this format on error.
 */
export interface APIError {
  /** Error type identifier (e.g., "not_found", "invalid_request") */
  error: string;
  /** Human-readable error message */
  message: string;
  /** HTTP status code */
  code: number;
}

/**
 * Type guard to check if an error is an APIError.
 */
export function isAPIError(err: unknown): err is APIError {
  return (
    typeof err === 'object' &&
    err !== null &&
    'error' in err &&
    'message' in err &&
    'code' in err
  );
}

/**
 * Safely extract error message from any error type.
 */
export function getErrorMessage(err: unknown): string {
  if (isAPIError(err)) {
    return err.message;
  }
  if (err instanceof Error) {
    return err.message;
  }
  if (typeof err === 'string') {
    return err;
  }
  return 'An unexpected error occurred';
}

/**
 * Common error codes returned by the API.
 */
export const ErrorCodes = {
  INVALID_REQUEST: 'invalid_request',
  UNAUTHORIZED: 'unauthorized',
  FORBIDDEN: 'forbidden',
  NOT_FOUND: 'not_found',
  CONFLICT: 'conflict',
  RATE_LIMIT_EXCEEDED: 'rate_limit_exceeded',
  SERVER_ERROR: 'server_error',
  DATABASE_ERROR: 'database_error',
  SERVICE_UNAVAILABLE: 'service_unavailable',
} as const;

export type ErrorCode = typeof ErrorCodes[keyof typeof ErrorCodes];

export interface Batch {
  id: string;
  status: 'pending' | 'processing' | 'completed' | 'failed';
  total_count: number;
  completed_count: number;
  failed_count: number;
  created_at: string;
  updated_at: string;
}

export interface BatchResponse {
  batch: Batch;
  transcripts: Transcript[];
}

export type AudioContentType = 'general' | 'phone_call' | 'meeting' | 'voice_memo' | 'interview' | 'lecture';

export interface AudioTranscription {
  id: string;
  filename: string;
  original_name: string;
  audio_s3_key?: string;
  audio_s3_status?: string;
  audio_s3_size?: number;
  processing_stage?: string;
  processing_progress?: number;
  retry_count?: number;
  duration: number;
  language: string;
  transcript_text: string;
  word_count: number;
  status: 'pending' | 'processing' | 'completed' | 'failed';
  error_message?: string;
  content_type: AudioContentType;
  summary_text?: string;
  key_points: string[];
  action_items: string[];
  decisions: string[];
  summary_model?: string;
  summary_status: 'none' | 'processing' | 'completed' | 'failed';
  created_at: string;
}

export interface AudioPlaybackResponse {
  url: string;
  expires_in: string;
}

export interface AudioUploadPresignResponse {
  upload_url: string;
  object_key: string;
  stored_name: string;
  upload_id: string;
  expires_in: string;
}

export interface AudioOpsHealth {
  queue_size: number;
  worker_count: number;
  pending: number;
  processing: number;
  failed: number;
  completed: number;
  created_last24h: number;
  timestamp: string;
}

export interface PDFExtraction {
  id: string;
  filename: string;
  original_name: string;
  page_count: number;
  text_content: string;
  word_count: number;
  status: 'completed' | 'failed';
  error_message?: string;
  created_at: string;
}

export interface AuthResponse {
  token: string;
  user: { id: string; email: string; name: string; created_at: string };
}

export interface WorkspaceResponse {
  transcripts: Transcript[];
  audio: AudioTranscription[];
  pdfs: PDFExtraction[];
}

export interface Webhook {
  id: string;
  url: string;
  events: string[];
  active: boolean;
  created_at: string;
  secret?: string;
}

export interface WebhookDelivery {
  id: string;
  webhook_id: string;
  event: string;
  status: 'pending' | 'success' | 'failed';
  attempts: number;
  last_error?: string;
  response_code: number;
  created_at: string;
  delivered_at?: string;
}

export type ExportFormat = 'txt' | 'md' | 'srt' | 'json';

// ── Helpers ──

async function getHeaders(): Promise<Record<string, string>> {
  return getAuthHeadersAsync();
}

async function getUploadHeaders(): Promise<Record<string, string>> {
  return getAuthUploadHeadersAsync();
}

function getAPIKeyHeaders(): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  const apiKey = localStorage.getItem('mta_api_key');
  if (apiKey) headers['X-API-Key'] = apiKey;
  return headers;
}

async function handleResponse<T>(response: Response): Promise<T> {
  if (!response.ok) {
    const error: APIError = await response.json().catch(() => ({
      error: 'unknown',
      message: `HTTP ${response.status}: ${response.statusText}`,
      code: response.status,
    }));
    throw error;
  }
  return response.json();
}

// ── Health ──

export async function getHealth(): Promise<HealthResponse> {
  const res = await fetch(`${API_BASE}/health`);
  return handleResponse<HealthResponse>(res);
}

// ── API Keys ──

export async function createAPIKey(name: string, options?: { rateLimit?: number; adminKey?: string }): Promise<APIKey> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (options?.adminKey) {
    headers['X-Admin-Key'] = options.adminKey;
  }
  const res = await fetch(`${API_BASE}/keys`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ name, rate_limit: options?.rateLimit }),
  });
  return handleResponse<APIKey>(res);
}

// ── Transcripts ──

export async function createTranscript(url: string): Promise<Transcript> {
  const res = await fetch(`${API_BASE}/transcripts`, {
    method: 'POST',
    headers: await getHeaders(),
    body: JSON.stringify({ url }),
  });
  return handleResponse<Transcript>(res);
}

export async function getTranscript(id: string): Promise<Transcript> {
  const res = await fetch(`${API_BASE}/transcripts/${id}`, { headers: await getHeaders() });
  return handleResponse<Transcript>(res);
}

export async function listTranscripts(params?: {
  page?: number;
  per_page?: number;
  status?: string;
  search?: string;
}): Promise<PaginatedResponse<Transcript>> {
  const searchParams = new URLSearchParams();
  if (params?.page) searchParams.set('page', String(params.page));
  if (params?.per_page) searchParams.set('per_page', String(params.per_page));
  if (params?.status) searchParams.set('status', params.status);
  if (params?.search) searchParams.set('search', params.search);
  const res = await fetch(`${API_BASE}/transcripts?${searchParams}`, { headers: await getHeaders() });
  return handleResponse<PaginatedResponse<Transcript>>(res);
}

// ── Chat (MTA-27) ──

function getChatPath(itemType: ChatItemType, itemId: string): string {
  switch (itemType) {
    case 'audio':
      return `${API_BASE}/audio/transcriptions/${itemId}/chat`;
    case 'pdf':
      return `${API_BASE}/pdf/extractions/${itemId}/chat`;
    case 'collection':
      return `${API_BASE}/collections/${itemId}/chat`;
    case 'transcript':
    default:
      return `${API_BASE}/transcripts/${itemId}/chat`;
  }
}

export async function getChat(itemType: ChatItemType, itemId: string): Promise<ChatResponse> {
  const res = await fetch(getChatPath(itemType, itemId), { headers: await getHeaders() });
  return handleResponse<ChatResponse>(res);
}

export async function sendChatMessage(
  itemType: ChatItemType,
  itemId: string,
  message: string,
  options?: { model?: string }
): Promise<ChatResponse> {
  const res = await fetch(getChatPath(itemType, itemId), {
    method: 'POST',
    headers: await getHeaders(),
    body: JSON.stringify({ message, model: options?.model }),
  });
  return handleResponse<ChatResponse>(res);
}

export async function deleteTranscript(id: string): Promise<void> {
  const res = await fetch(`${API_BASE}/transcripts/${id}`, { method: 'DELETE', headers: await getHeaders() });
  if (!res.ok && res.status !== 404) {
    const error: APIError = await res.json().catch(() => ({
      error: 'unknown', message: `HTTP ${res.status}: ${res.statusText}`, code: res.status,
    }));
    throw error;
  }
}

// ── Summaries ──

export async function createSummary(
  transcriptId: string,
  options?: { length?: string; style?: string; model?: string }
): Promise<{ message: string; transcript_id: string }> {
  const res = await fetch(`${API_BASE}/summaries`, {
    method: 'POST',
    headers: await getHeaders(),
    body: JSON.stringify({ transcript_id: transcriptId, ...options }),
  });
  return handleResponse(res);
}

export async function getSummaries(transcriptId: string): Promise<Summary[]> {
  const res = await fetch(`${API_BASE}/transcripts/${transcriptId}/summaries`, { headers: await getHeaders() });
  return handleResponse<Summary[]>(res);
}

// ── Batch Processing ──

export async function createBatch(urls: string[]): Promise<BatchResponse> {
  const res = await fetch(`${API_BASE}/transcripts/batch`, {
    method: 'POST',
    headers: await getHeaders(),
    body: JSON.stringify({ urls }),
  });
  return handleResponse<BatchResponse>(res);
}

export async function getBatch(batchId: string): Promise<BatchResponse> {
  const res = await fetch(`${API_BASE}/batches/${batchId}`, { headers: await getHeaders() });
  return handleResponse<BatchResponse>(res);
}

// ── Export ──

export function getExportUrl(transcriptId: string, format: ExportFormat): string {
  return `${API_BASE}/transcripts/${transcriptId}/export?format=${format}`;
}

export async function downloadExport(transcriptId: string, format: ExportFormat): Promise<Blob> {
  const res = await fetch(getExportUrl(transcriptId, format), { headers: await getHeaders() });
  if (!res.ok) throw new Error(`Export failed: ${res.statusText}`);
  return res.blob();
}

// ── LocalStorage History ──

const HISTORY_KEY = 'mta_transcript_ids';

export function getStoredTranscriptIds(): string[] {
  try {
    const raw = localStorage.getItem(HISTORY_KEY);
    if (!raw) return [];
    return JSON.parse(raw) as string[];
  } catch { return []; }
}

export function addTranscriptToHistory(id: string): void {
  const ids = getStoredTranscriptIds();
  if (!ids.includes(id)) {
    ids.unshift(id);
    localStorage.setItem(HISTORY_KEY, JSON.stringify(ids.slice(0, 100)));
  }
}

export function removeTranscriptsFromHistory(idsToRemove: string[]): void {
  const ids = getStoredTranscriptIds();
  const filtered = ids.filter((id) => !idsToRemove.includes(id));
  localStorage.setItem(HISTORY_KEY, JSON.stringify(filtered));
}

// ── Audio Transcription (MTA-16) ──

export async function transcribeAudio(file: File): Promise<AudioTranscription> {
  const formData = new FormData();
  formData.append('file', file);
  const res = await fetch(`${API_BASE}/audio/transcribe`, {
    method: 'POST', headers: await getUploadHeaders(), body: formData,
  });
  return handleResponse<AudioTranscription>(res);
}

export async function presignAudioUpload(file: File): Promise<AudioUploadPresignResponse> {
  const res = await fetch(`${API_BASE}/audio/uploads/presign`, {
    method: 'POST',
    headers: await getHeaders(),
    body: JSON.stringify({
      filename: file.name,
      content_type: file.type || 'application/octet-stream',
      size_bytes: file.size,
    }),
  });
  return handleResponse<AudioUploadPresignResponse>(res);
}

export function uploadAudioToPresignedUrl(
  url: string,
  file: File,
  options: {
    onProgress?: (percent: number) => void;
    stallTimeoutMs?: number;
  } = {}
): Promise<void> {
  const stallTimeoutMs = options.stallTimeoutMs ?? 60000;

  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    let settled = false;
    let stallTimer: ReturnType<typeof setTimeout> | null = null;

    const finish = (err?: Error) => {
      if (settled) return;
      settled = true;
      if (stallTimer) clearTimeout(stallTimer);
      if (err) {
        reject(err);
      } else {
        resolve();
      }
    };

    const resetStallTimer = () => {
      if (stallTimer) clearTimeout(stallTimer);
      stallTimer = setTimeout(() => {
        xhr.abort();
        finish(new Error('Storage upload stalled. Retrying through the API.'));
      }, stallTimeoutMs);
    };

    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable && event.total > 0) {
        const percent = Math.round((event.loaded / event.total) * 100);
        options.onProgress?.(percent);
        if (event.loaded >= event.total) {
          if (stallTimer) clearTimeout(stallTimer);
          stallTimer = null;
          return;
        }
      }
      resetStallTimer();
    };

    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        options.onProgress?.(100);
        finish();
      } else {
        finish(new Error(`Storage upload failed: ${xhr.status}`));
      }
    };
    xhr.onerror = () => finish(new Error('Storage upload failed. Retrying through the API.'));
    xhr.onabort = () => finish(new Error('Storage upload was interrupted. Retrying through the API.'));

    xhr.open('PUT', url);
    xhr.setRequestHeader('Content-Type', file.type || 'application/octet-stream');
    resetStallTimer();
    xhr.send(file);
  });
}

export async function completeAudioUpload(params: {
  object_key: string;
  original_name: string;
  size_bytes: number;
}): Promise<AudioTranscription> {
  const res = await fetch(`${API_BASE}/audio/uploads/complete`, {
    method: 'POST',
    headers: await getHeaders(),
    body: JSON.stringify(params),
  });
  return handleResponse<AudioTranscription>(res);
}

export async function getAudioTranscription(id: string): Promise<AudioTranscription> {
  const res = await fetch(`${API_BASE}/audio/transcriptions/${id}`, { headers: await getHeaders() });
  return handleResponse<AudioTranscription>(res);
}

export async function renameAudioTranscription(id: string, name: string): Promise<AudioTranscription> {
  const res = await fetch(`${API_BASE}/audio/transcriptions/${id}`, {
    method: 'PATCH',
    headers: await getHeaders(),
    body: JSON.stringify({ name }),
  });
  return handleResponse<AudioTranscription>(res);
}

export async function retryAudioTranscription(id: string): Promise<AudioTranscription> {
  const res = await fetch(`${API_BASE}/audio/transcriptions/${id}/retry`, {
    method: 'POST',
    headers: await getHeaders(),
  });
  return handleResponse<AudioTranscription>(res);
}

export async function cancelAudioTranscription(id: string): Promise<AudioTranscription> {
  const res = await fetch(`${API_BASE}/audio/transcriptions/${id}/cancel`, {
    method: 'POST',
    headers: await getHeaders(),
  });
  return handleResponse<AudioTranscription>(res);
}

export async function getAudioPlaybackUrl(id: string): Promise<AudioPlaybackResponse> {
  const res = await fetch(`${API_BASE}/audio/transcriptions/${id}/audio`, { headers: await getHeaders() });
  return handleResponse<AudioPlaybackResponse>(res);
}

export async function getAudioOpsHealth(): Promise<AudioOpsHealth> {
  const res = await fetch(`${API_BASE}/ops/audio/health`, { headers: getAPIKeyHeaders() });
  return handleResponse<AudioOpsHealth>(res);
}

export async function listAudioTranscriptions(): Promise<AudioTranscription[]> {
  const res = await fetch(`${API_BASE}/audio/transcriptions`, { headers: await getHeaders() });
  return handleResponse<AudioTranscription[]>(res);
}

export async function deleteAudioTranscription(id: string): Promise<void> {
  const res = await fetch(`${API_BASE}/audio/transcriptions/${id}`, { method: 'DELETE', headers: await getHeaders() });
  if (!res.ok && res.status !== 404) {
    const error: APIError = await res.json().catch(() => ({
      error: 'unknown', message: `HTTP ${res.status}: ${res.statusText}`, code: res.status,
    }));
    throw error;
  }
}

// MTA-22: Summarize an audio transcription
export async function summarizeAudio(
  id: string,
  options?: { content_type?: AudioContentType; model?: string; length?: string }
): Promise<AudioTranscription> {
  const res = await fetch(`${API_BASE}/audio/transcriptions/${id}/summarize`, {
    method: 'POST',
    headers: await getHeaders(),
    body: JSON.stringify(options || {}),
  });
  return handleResponse<AudioTranscription>(res);
}

// MTA-25: Search audio transcriptions
export async function searchAudioTranscriptions(params?: {
  q?: string;
  content_type?: string;
  page?: number;
  per_page?: number;
}): Promise<PaginatedResponse<AudioTranscription>> {
  const searchParams = new URLSearchParams();
  if (params?.q) searchParams.set('q', params.q);
  if (params?.content_type) searchParams.set('content_type', params.content_type);
  if (params?.page) searchParams.set('page', String(params.page));
  if (params?.per_page) searchParams.set('per_page', String(params.per_page));
  const res = await fetch(`${API_BASE}/audio/transcriptions/search?${searchParams}`, { headers: await getHeaders() });
  return handleResponse<PaginatedResponse<AudioTranscription>>(res);
}

// MTA-26: Export audio transcription
export function getAudioExportUrl(id: string, format: 'txt' | 'md' | 'json'): string {
  return `${API_BASE}/audio/transcriptions/${id}/export?format=${format}`;
}

export async function downloadAudioExport(id: string, format: 'txt' | 'md' | 'json'): Promise<Blob> {
  const res = await fetch(getAudioExportUrl(id, format), { headers: await getHeaders() });
  if (!res.ok) throw new Error(`Export failed: ${res.statusText}`);
  return res.blob();
}

// ── PDF Extraction (MTA-17) ──

export async function extractPDF(file: File): Promise<PDFExtraction> {
  const formData = new FormData();
  formData.append('file', file);
  const res = await fetch(`${API_BASE}/pdf/extract`, {
    method: 'POST', headers: await getUploadHeaders(), body: formData,
  });
  return handleResponse<PDFExtraction>(res);
}

export async function getPDFExtraction(id: string): Promise<PDFExtraction> {
  const res = await fetch(`${API_BASE}/pdf/extractions/${id}`, { headers: await getHeaders() });
  return handleResponse<PDFExtraction>(res);
}

export async function listPDFExtractions(): Promise<PDFExtraction[]> {
  const res = await fetch(`${API_BASE}/pdf/extractions`, { headers: await getHeaders() });
  return handleResponse<PDFExtraction[]>(res);
}

export async function deletePDFExtraction(id: string): Promise<void> {
  const res = await fetch(`${API_BASE}/pdf/extractions/${id}`, { method: 'DELETE', headers: await getHeaders() });
  if (!res.ok && res.status !== 404) {
    const error: APIError = await res.json().catch(() => ({
      error: 'unknown', message: `HTTP ${res.status}: ${res.statusText}`, code: res.status,
    }));
    throw error;
  }
}

// ── Auth (MTA-20) ──

export async function register(email: string, password: string, name: string): Promise<AuthResponse> {
  const res = await fetch(`${API_BASE}/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password, name }),
  });
  return handleResponse<AuthResponse>(res);
}

export async function login(email: string, password: string): Promise<AuthResponse> {
  const res = await fetch(`${API_BASE}/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  return handleResponse<AuthResponse>(res);
}

export async function refreshToken(): Promise<AuthResponse> {
  const res = await fetch(`${API_BASE}/auth/refresh`, {
    method: 'POST',
    headers: await getHeaders(),
  });
  return handleResponse<AuthResponse>(res);
}

// ── Workspace (MTA-20) ──

export async function getWorkspace(): Promise<WorkspaceResponse> {
  const res = await fetch(`${API_BASE}/workspace`, { headers: await getHeaders() });
  return handleResponse<WorkspaceResponse>(res);
}

export async function saveToWorkspace(itemType: string, itemId: string): Promise<void> {
  const res = await fetch(`${API_BASE}/workspace`, {
    method: 'POST',
    headers: await getHeaders(),
    body: JSON.stringify({ item_type: itemType, item_id: itemId }),
  });
  if (!res.ok) {
    const error: APIError = await res.json().catch(() => ({
      error: 'unknown', message: `HTTP ${res.status}`, code: res.status,
    }));
    throw error;
  }
}

export async function removeFromWorkspace(itemType: string, itemId: string): Promise<void> {
  const res = await fetch(`${API_BASE}/workspace/${itemType}/${itemId}`, {
    method: 'DELETE', headers: await getHeaders(),
  });
  if (!res.ok) {
    const error: APIError = await res.json().catch(() => ({
      error: 'unknown', message: `HTTP ${res.status}`, code: res.status,
    }));
    throw error;
  }
}

// ── Webhooks (MTA-18) ──

export async function createWebhook(url: string, events: string[]): Promise<Webhook> {
  const res = await fetch(`${API_BASE}/webhooks`, {
    method: 'POST', headers: getAPIKeyHeaders(), body: JSON.stringify({ url, events }),
  });
  return handleResponse<Webhook>(res);
}

export async function listWebhooks(): Promise<Webhook[]> {
  const res = await fetch(`${API_BASE}/webhooks`, { headers: getAPIKeyHeaders() });
  return handleResponse<Webhook[]>(res);
}

export async function updateWebhook(id: string, active: boolean): Promise<void> {
  const res = await fetch(`${API_BASE}/webhooks/${id}`, {
    method: 'PATCH', headers: getAPIKeyHeaders(), body: JSON.stringify({ active }),
  });
  if (!res.ok) throw new Error('Failed to update webhook');
}

export async function deleteWebhook(id: string): Promise<void> {
  const res = await fetch(`${API_BASE}/webhooks/${id}`, { method: 'DELETE', headers: getAPIKeyHeaders() });
  if (!res.ok) throw new Error('Failed to delete webhook');
}

export async function listWebhookDeliveries(): Promise<WebhookDelivery[]> {
  const res = await fetch(`${API_BASE}/webhooks/deliveries`, { headers: getAPIKeyHeaders() });
  return handleResponse<WebhookDelivery[]>(res);
}

// ── Collections ──

export interface Collection {
  id: string;
  name: string;
  description: string;
  user_id?: string;
  api_key_id?: string;
  item_count: number;
  created_at: string;
  updated_at: string;
}

export interface CollectionItem {
  id: string;
  collection_id: string;
  item_type: 'transcript' | 'audio' | 'pdf';
  item_id: string;
  item_title?: string;
  item_status?: string;
  position: number;
  added_at: string;
}

export interface CollectionWithItems extends Collection {
  items: CollectionItem[];
}

export async function listCollections(): Promise<Collection[]> {
  const res = await fetch(`${API_BASE}/collections`, { headers: await getHeaders() });
  return handleResponse<Collection[]>(res);
}

export async function createCollection(name: string, description?: string): Promise<Collection> {
  const res = await fetch(`${API_BASE}/collections`, {
    method: 'POST', headers: await getHeaders(), body: JSON.stringify({ name, description: description || '' }),
  });
  return handleResponse<Collection>(res);
}

export async function getCollection(id: string): Promise<CollectionWithItems> {
  const res = await fetch(`${API_BASE}/collections/${id}`, { headers: await getHeaders() });
  return handleResponse<CollectionWithItems>(res);
}

export async function updateCollection(id: string, data: { name?: string; description?: string }): Promise<Collection> {
  const res = await fetch(`${API_BASE}/collections/${id}`, {
    method: 'PATCH', headers: await getHeaders(), body: JSON.stringify(data),
  });
  return handleResponse<Collection>(res);
}

export async function deleteCollection(id: string): Promise<void> {
  const res = await fetch(`${API_BASE}/collections/${id}`, { method: 'DELETE', headers: await getHeaders() });
  if (!res.ok) throw new Error('Failed to delete collection');
}

export async function addCollectionItems(id: string, items: { item_type: string; item_id: string }[]): Promise<{ added: number }> {
  const res = await fetch(`${API_BASE}/collections/${id}/items`, {
    method: 'POST', headers: await getHeaders(), body: JSON.stringify({ items }),
  });
  return handleResponse<{ added: number }>(res);
}

export async function removeCollectionItem(collectionId: string, itemId: string): Promise<void> {
  const res = await fetch(`${API_BASE}/collections/${collectionId}/items/${itemId}`, { method: 'DELETE', headers: await getHeaders() });
  if (!res.ok) throw new Error('Failed to remove item from collection');
}
