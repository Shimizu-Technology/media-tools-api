import { renewWebSession, setWebSessionActive, webCSRFHeaders, type WebSessionStatus } from './webSession';

type JSONRecord = Record<string, unknown>;
type PasskeyBegin = { ceremony_id: string; options: JSONRecord };
type PasskeyStatus = { count: number };

const webLoginBase = '/api/v1/auth/web/session/passkeys/login';
const registrationBase = '/api/v1/auth/passkeys/register';
const loginJournalKey = 'mta:web-passkey-login:v1';
let signInRequest: Promise<void> | null = null;
let registrationRequest: Promise<number> | null = null;

export class PasskeyError extends Error {
  readonly code: string;
  constructor(message: string, code = 'passkey_error') {
    super(message);
    this.name = 'PasskeyError';
    this.code = code;
  }
}

export function passkeysSupported(): boolean {
  return typeof window !== 'undefined' && window.isSecureContext &&
    typeof PublicKeyCredential !== 'undefined' && Boolean(navigator.credentials);
}

export function signInWithPasskey(): Promise<void> {
  if (signInRequest) return signInRequest;
  signInRequest = performPasskeySignIn().finally(() => { signInRequest = null; });
  return signInRequest;
}

async function performPasskeySignIn(): Promise<void> {
  requirePasskeys();
  if (await recoverPendingPasskeySignIn()) return;
  const begin = await requestJSON<PasskeyBegin>(`${webLoginBase}/begin`, {
    method: 'POST', credentials: 'same-origin',
  });
  const credential = await navigator.credentials.get({
    publicKey: parseRequestOptions(begin.options),
  });
  if (!(credential instanceof PublicKeyCredential)) {
    throw new PasskeyError('No passkey was selected.', 'passkey_cancelled');
  }
  writeLoginJournal(begin.ceremony_id);
  await finishPasskeySignIn(begin.ceremony_id, credentialToJSON(credential));
}

export async function recoverPendingPasskeySignIn(): Promise<boolean> {
  const ceremonyID = readLoginJournal();
  if (!ceremonyID) return false;
  try {
    await finishPasskeySignIn(ceremonyID);
    return true;
  } catch (error) {
    if (error instanceof PasskeyError && ['invalid_challenge', 'invalid_request', 'sign_in_not_prepared'].includes(error.code)) {
      clearPasskeySignInJournal();
      return false;
    }
    throw error;
  }
}

async function finishPasskeySignIn(ceremonyID: string, credential?: JSONRecord): Promise<void> {
  await requestJSON(`${webLoginBase}/finish`, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...webCSRFHeaders() },
    body: JSON.stringify({ ceremony_id: ceremonyID, ...(credential ? { credential } : {}) }),
  });
  await requestJSON<WebSessionStatus>('/api/v1/auth/web/session/status', { credentials: 'same-origin' });
  setWebSessionActive(true);
  clearPasskeySignInJournal();
}

function writeLoginJournal(ceremonyID: string): void {
  try { localStorage.setItem(loginJournalKey, ceremonyID); } catch { /* The immediate attempt can still succeed. */ }
}

function readLoginJournal(): string | null {
  try { return localStorage.getItem(loginJournalKey); } catch { return null; }
}

export function clearPasskeySignInJournal(): void {
  try { localStorage.removeItem(loginJournalKey); } catch { /* Best effort after a confirmed session. */ }
}

export async function getPasskeyStatus(): Promise<PasskeyStatus> {
  const status = await requestJSON<PasskeyStatus>('/api/v1/auth/passkeys', {
    credentials: 'same-origin',
  });
  return { count: Number.isInteger(status.count) && status.count >= 0 ? status.count : 0 };
}

export function registerPasskey(): Promise<number> {
  if (registrationRequest) return registrationRequest;
  registrationRequest = performPasskeyRegistration().finally(() => { registrationRequest = null; });
  return registrationRequest;
}

async function performPasskeyRegistration(): Promise<number> {
  requirePasskeys();
  const before = await getPasskeyStatus();
  const begin = await requestJSON<PasskeyBegin>(`${registrationBase}/begin`, {
    method: 'POST', credentials: 'same-origin', headers: webCSRFHeaders(),
  });
  const credential = await navigator.credentials.create({
    publicKey: parseCreationOptions(begin.options),
  });
  if (!(credential instanceof PublicKeyCredential)) {
    throw new PasskeyError('A passkey was not created.', 'passkey_cancelled');
  }
  try {
    await requestJSON(`${registrationBase}/finish`, {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', ...webCSRFHeaders() },
      body: JSON.stringify({ ceremony_id: begin.ceremony_id, credential: credentialToJSON(credential) }),
    });
  } catch (error) {
    // If the server committed the credential but its response disappeared,
    // status is the durable receipt. This avoids prompting for a duplicate.
    const after = await getPasskeyStatus().catch(() => null);
    if (!after || after.count <= before.count) throw error;
    return after.count;
  }
  return before.count + 1;
}

function requirePasskeys(): void {
  if (!passkeysSupported()) {
    throw new PasskeyError('Passkeys need a current browser on a secure connection.', 'passkey_unsupported');
  }
}

async function requestJSON<T = JSONRecord>(url: string, init: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(url, init);
    if (response.status === 401 && isPasskeyManagementRequest(url)) {
      const body = await response.clone().json().catch(() => null) as { error?: string } | null;
      if (body?.error === 'unauthorized') {
        const renewal = await renewWebSession();
        if (renewal === 'renewed') {
          const headers = Object.fromEntries(new Headers(init.headers));
          response = await fetch(url, { ...init, headers: { ...headers, ...webCSRFHeaders() } });
        } else if (renewal === 'invalid') {
          setWebSessionActive(false);
        } else {
          throw new PasskeyError('Could not renew your session. Please try again.', 'authentication_unavailable');
        }
      }
    }
  } catch (error) {
    if (error instanceof PasskeyError) throw error;
    throw new PasskeyError('Could not reach Media Tools. Check your connection and try again.', 'network_error');
  }
  if (!response.ok) {
    const body = await response.json().catch(() => null) as { error?: string; message?: string } | null;
    throw new PasskeyError(body?.message || 'Passkey request failed. Please try again.', body?.error || 'passkey_error');
  }
  if (response.status === 204) return {} as T;
  return await response.json() as T;
}

function isPasskeyManagementRequest(url: string): boolean {
  return url === '/api/v1/auth/passkeys' || url.startsWith('/api/v1/auth/passkeys/register/');
}

export function parseRequestOptions(options: JSONRecord): PublicKeyCredentialRequestOptions {
  const parser = (PublicKeyCredential as typeof PublicKeyCredential & {
    parseRequestOptionsFromJSON?: (value: JSONRecord) => PublicKeyCredentialRequestOptions;
  }).parseRequestOptionsFromJSON;
  if (parser) return parser(options);
  return {
    ...options,
    challenge: base64URLToBytes(String(options.challenge)),
    allowCredentials: Array.isArray(options.allowCredentials)
      ? options.allowCredentials.map((item) => {
        const descriptor = item as JSONRecord;
        return { ...descriptor, id: base64URLToBytes(String(descriptor.id)) } as PublicKeyCredentialDescriptor;
      })
      : undefined,
  } as PublicKeyCredentialRequestOptions;
}

export function parseCreationOptions(options: JSONRecord): PublicKeyCredentialCreationOptions {
  const parser = (PublicKeyCredential as typeof PublicKeyCredential & {
    parseCreationOptionsFromJSON?: (value: JSONRecord) => PublicKeyCredentialCreationOptions;
  }).parseCreationOptionsFromJSON;
  if (parser) return parser(options);
  const user = options.user as JSONRecord;
  return {
    ...options,
    challenge: base64URLToBytes(String(options.challenge)),
    user: { ...user, id: base64URLToBytes(String(user.id)) },
    excludeCredentials: Array.isArray(options.excludeCredentials)
      ? options.excludeCredentials.map((item) => {
        const descriptor = item as JSONRecord;
        return { ...descriptor, id: base64URLToBytes(String(descriptor.id)) } as PublicKeyCredentialDescriptor;
      })
      : undefined,
  } as PublicKeyCredentialCreationOptions;
}

export function credentialToJSON(credential: PublicKeyCredential): JSONRecord {
  const native = credential as PublicKeyCredential & { toJSON?: () => JSONRecord };
  if (native.toJSON) return native.toJSON();
  const response = credential.response;
  const common = {
    id: credential.id,
    rawId: bytesToBase64URL(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment,
    clientExtensionResults: credential.getClientExtensionResults(),
  };
  if (response instanceof AuthenticatorAssertionResponse) {
    return {
      ...common,
      response: {
        clientDataJSON: bytesToBase64URL(response.clientDataJSON),
        authenticatorData: bytesToBase64URL(response.authenticatorData),
        signature: bytesToBase64URL(response.signature),
        userHandle: response.userHandle ? bytesToBase64URL(response.userHandle) : null,
      },
    };
  }
  const attestation = response as AuthenticatorAttestationResponse;
  return {
    ...common,
    response: {
      clientDataJSON: bytesToBase64URL(attestation.clientDataJSON),
      attestationObject: bytesToBase64URL(attestation.attestationObject),
      transports: typeof attestation.getTransports === 'function' ? attestation.getTransports() : [],
    },
  };
}

function base64URLToBytes(value: string): ArrayBuffer {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
  const binary = atob(padded);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return bytes.buffer;
}

function bytesToBase64URL(value: ArrayBuffer): string {
  const bytes = new Uint8Array(value);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
