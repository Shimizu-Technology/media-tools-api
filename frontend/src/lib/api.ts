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
