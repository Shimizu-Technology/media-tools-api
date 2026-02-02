/**
 * API client for the Media Tools API.
 *
 * This module provides typed functions for all API endpoints.
 * During development, Vite proxies /api requests to localhost:8080.
 */

const API_BASE = '/api/v1';

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
  raw_key?: string; // Only present on creation
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

export interface APIError {
  error: string;
  message: string;
  code: number;
}

// ── Helper ──

function getHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };

  // Include API key if stored
  const apiKey = localStorage.getItem('mta_api_key');
  if (apiKey) {
    headers['X-API-Key'] = apiKey;
  }

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

// ── API Functions ──

/** Check API health */
export async function getHealth(): Promise<HealthResponse> {
  const res = await fetch(`${API_BASE}/health`);
  return handleResponse<HealthResponse>(res);
}

/** Create a new API key */
export async function createAPIKey(name: string, rateLimit?: number): Promise<APIKey> {
  const res = await fetch(`${API_BASE}/keys`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, rate_limit: rateLimit }),
  });
  return handleResponse<APIKey>(res);
}

/** Submit a YouTube URL for transcript extraction */
export async function createTranscript(url: string): Promise<Transcript> {
  const res = await fetch(`${API_BASE}/transcripts`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({ url }),
  });
  return handleResponse<Transcript>(res);
}

/** Get a single transcript by ID */
export async function getTranscript(id: string): Promise<Transcript> {
  const res = await fetch(`${API_BASE}/transcripts/${id}`, {
    headers: getHeaders(),
  });
  return handleResponse<Transcript>(res);
}

/** List transcripts with pagination */
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

  const res = await fetch(`${API_BASE}/transcripts?${searchParams}`, {
    headers: getHeaders(),
  });
  return handleResponse<PaginatedResponse<Transcript>>(res);
}

/** Request an AI summary for a transcript */
export async function createSummary(
  transcriptId: string,
  options?: { length?: string; style?: string; model?: string }
): Promise<{ message: string; transcript_id: string }> {
  const res = await fetch(`${API_BASE}/summaries`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      transcript_id: transcriptId,
      ...options,
    }),
  });
  return handleResponse(res);
}

/** Get summaries for a transcript */
export async function getSummaries(transcriptId: string): Promise<Summary[]> {
  const res = await fetch(`${API_BASE}/transcripts/${transcriptId}/summaries`, {
    headers: getHeaders(),
  });
  return handleResponse<Summary[]>(res);
}

// ── Batch Processing (MTA-8) ──

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

/** Submit multiple URLs for batch processing */
export async function createBatch(urls: string[]): Promise<BatchResponse> {
  const res = await fetch(`${API_BASE}/transcripts/batch`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({ urls }),
  });
  return handleResponse<BatchResponse>(res);
}

/** Get batch status */
export async function getBatch(batchId: string): Promise<BatchResponse> {
  const res = await fetch(`${API_BASE}/batches/${batchId}`, {
    headers: getHeaders(),
  });
  return handleResponse<BatchResponse>(res);
}

// ── Export (MTA-9) ──

export type ExportFormat = 'txt' | 'md' | 'srt' | 'json';

/** Get the export download URL for a transcript */
export function getExportUrl(transcriptId: string, format: ExportFormat): string {
  return `${API_BASE}/transcripts/${transcriptId}/export?format=${format}`;
}

/** Download a transcript export as a blob */
export async function downloadExport(transcriptId: string, format: ExportFormat): Promise<Blob> {
  const res = await fetch(getExportUrl(transcriptId, format), {
    headers: getHeaders(),
  });
  if (!res.ok) {
    throw new Error(`Export failed: ${res.statusText}`);
  }
  return res.blob();
}

// ── Delete + History (MTA-13) ──

/** Delete a transcript by ID */
export async function deleteTranscript(id: string): Promise<void> {
  const res = await fetch(`${API_BASE}/transcripts/${id}`, {
    method: 'DELETE',
    headers: getHeaders(),
  });
  if (!res.ok && res.status !== 404) {
    const error: APIError = await res.json().catch(() => ({
      error: 'unknown',
      message: `HTTP ${res.status}: ${res.statusText}`,
      code: res.status,
    }));
    throw error;
  }
}

// ── LocalStorage helpers for history tracking ──

const HISTORY_KEY = 'mta_transcript_ids';

/** Get stored transcript IDs from localStorage */
export function getStoredTranscriptIds(): string[] {
  try {
    const raw = localStorage.getItem(HISTORY_KEY);
    if (!raw) return [];
    return JSON.parse(raw) as string[];
  } catch {
    return [];
  }
}

/** Add a transcript ID to localStorage history */
export function addTranscriptToHistory(id: string): void {
  const ids = getStoredTranscriptIds();
  if (!ids.includes(id)) {
    ids.unshift(id);
    // Keep max 100 entries
    localStorage.setItem(HISTORY_KEY, JSON.stringify(ids.slice(0, 100)));
  }
}

/** Remove transcript IDs from localStorage history */
export function removeTranscriptsFromHistory(idsToRemove: string[]): void {
  const ids = getStoredTranscriptIds();
  const filtered = ids.filter((id) => !idsToRemove.includes(id));
  localStorage.setItem(HISTORY_KEY, JSON.stringify(filtered));
}
