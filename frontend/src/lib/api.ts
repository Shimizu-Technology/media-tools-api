/**
 * API client for the Media Tools API.
 * 
 * In development, Vite proxies /api requests to localhost:8080.
 * In production, VITE_API_URL points to the Render backend.
 */

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

function getHeaders(): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  const token = localStorage.getItem('mta_jwt_token');
  if (token) { headers['Authorization'] = `Bearer ${token}`; return headers; }
  const apiKey = localStorage.getItem('mta_api_key');
  if (apiKey) { headers['X-API-Key'] = apiKey; }
  return headers;
}

function getUploadHeaders(): Record<string, string> {
  const headers: Record<string, string> = {};
  const token = localStorage.getItem('mta_jwt_token');
  if (token) { headers['Authorization'] = `Bearer ${token}`; return headers; }
  const apiKey = localStorage.getItem('mta_api_key');
  if (apiKey) { headers['X-API-Key'] = apiKey; }
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
    headers: getHeaders(),
    body: JSON.stringify({ url }),
  });
  return handleResponse<Transcript>(res);
}

export async function getTranscript(id: string): Promise<Transcript> {
  const res = await fetch(`${API_BASE}/transcripts/${id}`, { headers: getHeaders() });
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
  const res = await fetch(`${API_BASE}/transcripts?${searchParams}`, { headers: getHeaders() });
  return handleResponse<PaginatedResponse<Transcript>>(res);
}

export async function deleteTranscript(id: string): Promise<void> {
  const res = await fetch(`${API_BASE}/transcripts/${id}`, { method: 'DELETE', headers: getHeaders() });
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
    headers: getHeaders(),
    body: JSON.stringify({ transcript_id: transcriptId, ...options }),
  });
  return handleResponse(res);
}

export async function getSummaries(transcriptId: string): Promise<Summary[]> {
  const res = await fetch(`${API_BASE}/transcripts/${transcriptId}/summaries`, { headers: getHeaders() });
  return handleResponse<Summary[]>(res);
}

// ── Batch Processing ──

export async function createBatch(urls: string[]): Promise<BatchResponse> {
  const res = await fetch(`${API_BASE}/transcripts/batch`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({ urls }),
  });
  return handleResponse<BatchResponse>(res);
}

export async function getBatch(batchId: string): Promise<BatchResponse> {
  const res = await fetch(`${API_BASE}/batches/${batchId}`, { headers: getHeaders() });
  return handleResponse<BatchResponse>(res);
}

// ── Export ──

export function getExportUrl(transcriptId: string, format: ExportFormat): string {
  return `${API_BASE}/transcripts/${transcriptId}/export?format=${format}`;
}

export async function downloadExport(transcriptId: string, format: ExportFormat): Promise<Blob> {
  const res = await fetch(getExportUrl(transcriptId, format), { headers: getHeaders() });
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
    method: 'POST', headers: getUploadHeaders(), body: formData,
  });
  return handleResponse<AudioTranscription>(res);
}

export async function getAudioTranscription(id: string): Promise<AudioTranscription> {
  const res = await fetch(`${API_BASE}/audio/transcriptions/${id}`, { headers: getHeaders() });
  return handleResponse<AudioTranscription>(res);
}

export async function listAudioTranscriptions(): Promise<AudioTranscription[]> {
  const res = await fetch(`${API_BASE}/audio/transcriptions`, { headers: getHeaders() });
  return handleResponse<AudioTranscription[]>(res);
}

export async function deleteAudioTranscription(id: string): Promise<void> {
  const res = await fetch(`${API_BASE}/audio/transcriptions/${id}`, { method: 'DELETE', headers: getHeaders() });
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
    headers: getHeaders(),
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
  const res = await fetch(`${API_BASE}/audio/transcriptions/search?${searchParams}`, { headers: getHeaders() });
  return handleResponse<PaginatedResponse<AudioTranscription>>(res);
}

// MTA-26: Export audio transcription
export function getAudioExportUrl(id: string, format: 'txt' | 'md' | 'json'): string {
  return `${API_BASE}/audio/transcriptions/${id}/export?format=${format}`;
}

export async function downloadAudioExport(id: string, format: 'txt' | 'md' | 'json'): Promise<Blob> {
  const res = await fetch(getAudioExportUrl(id, format), { headers: getHeaders() });
  if (!res.ok) throw new Error(`Export failed: ${res.statusText}`);
  return res.blob();
}

// ── PDF Extraction (MTA-17) ──

export async function extractPDF(file: File): Promise<PDFExtraction> {
  const formData = new FormData();
  formData.append('file', file);
  const res = await fetch(`${API_BASE}/pdf/extract`, {
    method: 'POST', headers: getUploadHeaders(), body: formData,
  });
  return handleResponse<PDFExtraction>(res);
}

export async function getPDFExtraction(id: string): Promise<PDFExtraction> {
  const res = await fetch(`${API_BASE}/pdf/extractions/${id}`, { headers: getHeaders() });
  return handleResponse<PDFExtraction>(res);
}

export async function listPDFExtractions(): Promise<PDFExtraction[]> {
  const res = await fetch(`${API_BASE}/pdf/extractions`, { headers: getHeaders() });
  return handleResponse<PDFExtraction[]>(res);
}

export async function deletePDFExtraction(id: string): Promise<void> {
  const res = await fetch(`${API_BASE}/pdf/extractions/${id}`, { method: 'DELETE', headers: getHeaders() });
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
    headers: getHeaders(),
  });
  return handleResponse<AuthResponse>(res);
}

// ── Workspace (MTA-20) ──

export async function getWorkspace(): Promise<WorkspaceResponse> {
  const res = await fetch(`${API_BASE}/workspace`, { headers: getHeaders() });
  return handleResponse<WorkspaceResponse>(res);
}

export async function saveToWorkspace(itemType: string, itemId: string): Promise<void> {
  const res = await fetch(`${API_BASE}/workspace`, {
    method: 'POST',
    headers: getHeaders(),
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
    method: 'DELETE', headers: getHeaders(),
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
    method: 'POST', headers: getHeaders(), body: JSON.stringify({ url, events }),
  });
  return handleResponse<Webhook>(res);
}

export async function listWebhooks(): Promise<Webhook[]> {
  const res = await fetch(`${API_BASE}/webhooks`, { headers: getHeaders() });
  return handleResponse<Webhook[]>(res);
}

export async function updateWebhook(id: string, active: boolean): Promise<void> {
  const res = await fetch(`${API_BASE}/webhooks/${id}`, {
    method: 'PATCH', headers: getHeaders(), body: JSON.stringify({ active }),
  });
  if (!res.ok) throw new Error('Failed to update webhook');
}

export async function deleteWebhook(id: string): Promise<void> {
  const res = await fetch(`${API_BASE}/webhooks/${id}`, { method: 'DELETE', headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to delete webhook');
}

export async function listWebhookDeliveries(): Promise<WebhookDelivery[]> {
  const res = await fetch(`${API_BASE}/webhooks/deliveries`, { headers: getHeaders() });
  return handleResponse<WebhookDelivery[]>(res);
}
