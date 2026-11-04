/** "0:31", "1:48", "12 min", "1 hr 12 min": the way a recording's length reads in a list. */
export function formatDuration(seconds?: number): string {
  if (!seconds || !Number.isFinite(seconds) || seconds < 1) return '';
  const total = Math.round(seconds);
  if (total < 600) return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
  const minutes = Math.round(total / 60);
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return rest ? `${hours} hr ${rest} min` : `${hours} hr`;
}

/** A running clock for the recorder and player: 00:42, 12:04, 1:02:09. */
export function formatClock(seconds: number, pad = false): string {
  const total = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const rest = total % 60;
  if (hours > 0) return `${hours}:${String(minutes).padStart(2, '0')}:${String(rest).padStart(2, '0')}`;
  return `${pad ? String(minutes).padStart(2, '0') : minutes}:${String(rest).padStart(2, '0')}`;
}

export function formatTimeOfDay(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  return new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }).format(date);
}

/** "Today, 9:12 AM", "Yesterday, 4:40 PM", "Tue, Nov 4, 9:12 AM". */
export function formatItemDate(value: string, now = new Date()): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  const startOf = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((startOf(now) - startOf(date)) / 86_400_000);
  const time = formatTimeOfDay(value);
  if (days === 0) return `Today, ${time}`;
  if (days === 1) return `Yesterday, ${time}`;
  const sameYear = date.getFullYear() === now.getFullYear();
  const day = new Intl.DateTimeFormat(undefined, sameYear ? { weekday: 'short', month: 'short', day: 'numeric' } : { month: 'short', day: 'numeric', year: 'numeric' }).format(date);
  return `${day}, ${time}`;
}

export function pluralize(count: number, one: string, many = `${one}s`): string {
  return `${count.toLocaleString()} ${count === 1 ? one : many}`;
}
