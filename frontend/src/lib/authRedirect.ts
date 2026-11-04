/**
 * Only same-origin app paths are valid sign-in destinations, so a crafted
 * `?next=` link can never send someone to another site after signing in.
 */
export function safeNextPath(value: string | null | undefined, fallback = '/app'): string {
  if (!value || !value.startsWith('/') || value.startsWith('//') || value.includes('\\')) return fallback;
  if (/^\/(sign-in|sign-up|forgot-password)(\/|\?|$)/.test(value)) return fallback;
  return value;
}
