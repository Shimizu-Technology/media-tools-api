/**
 * API auth headers.
 *
 * Browser requests authenticate with the HttpOnly session cookie that the
 * browser attaches itself; mutations add the matching CSRF header. Local
 * API-key development mode exists only under `vite dev`, so the key lookup
 * below is removed from production bundles at build time.
 */

import { localApiKeyMode, webCSRFHeaders } from './webSession';

function localApiKeyHeaders(): Record<string, string> {
  if (!localApiKeyMode) return {};
  const apiKey = localStorage.getItem('mta_api_key');
  return apiKey ? { 'X-API-Key': apiKey } : {};
}

/** Headers for JSON API calls. */
export async function getAuthHeadersAsync(): Promise<Record<string, string>> {
  return { 'Content-Type': 'application/json', ...webCSRFHeaders(), ...localApiKeyHeaders() };
}

/** Upload headers (no Content-Type, so the browser sets the multipart boundary). */
export async function getAuthUploadHeadersAsync(): Promise<Record<string, string>> {
  return { ...webCSRFHeaders(), ...localApiKeyHeaders() };
}
