/** Video summaries store key points as JSON text on some rows. */
export function parseKeyPoints(raw: unknown): string[] {
  if (Array.isArray(raw)) return raw.filter((value): value is string => typeof value === 'string');
  if (typeof raw === 'string') {
    try {
      const parsed: unknown = JSON.parse(raw);
      if (Array.isArray(parsed)) return parsed.filter((value): value is string => typeof value === 'string');
    } catch {
      return [];
    }
  }
  return [];
}
