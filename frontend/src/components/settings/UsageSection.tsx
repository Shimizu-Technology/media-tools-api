import { useCallback, useEffect, useState } from 'react';
import { Loader2 } from 'lucide-react';
import { AccountAuthError, getUsage, nextUsageReset, secondsToMinutes, usageFraction, type Usage } from '../../lib/accountAuth';
import { formatDate } from '../../lib/relativeTime';
import { SecondaryButton } from '../auth/fields';
import { SettingsCard } from './SettingsCard';

export function UsageSection() {
  const [usage, setUsage] = useState<Usage | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      setUsage(await getUsage());
    } catch (caught) {
      setError(caught instanceof AccountAuthError ? caught.message : 'Could not load your usage.');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const reset = usage ? nextUsageReset(usage.month) : null;
  return (
    <SettingsCard
      title="Usage this month"
      description={usage?.exempt ? 'This account has no monthly limits.' : reset ? `Limits reset on ${formatDate(reset)} (UTC).` : undefined}
      action={error ? <SecondaryButton type="button" onClick={() => void load()}>Try again</SecondaryButton> : undefined}
    >
      {loading && !usage && <p className="flex items-center gap-2 text-sm" role="status" style={{ color: 'var(--color-text-secondary)' }}><Loader2 className="h-4 w-4 animate-spin" />Loading usage…</p>}
      {error && <p role="alert" className="text-sm" style={{ color: 'var(--color-danger)' }}>{error}</p>}
      {usage && (
        <div className="grid gap-5 sm:grid-cols-2">
          <Meter label="Transcription" used={secondsToMinutes(usage.transcription_seconds)} limit={usage.exempt ? 0 : secondsToMinutes(usage.transcription_limit_seconds)} unit="min" />
          <Meter label="Summaries and chat" used={usage.ai_requests} limit={usage.exempt ? 0 : usage.ai_request_limit} unit="requests" />
        </div>
      )}
    </SettingsCard>
  );
}

function Meter({ label, used, limit, unit }: { label: string; used: number; limit: number; unit: string }) {
  const fraction = usageFraction(used, limit);
  const near = limit > 0 && fraction >= 0.9;
  return (
    <div>
      <div className="flex items-baseline justify-between gap-3 text-sm">
        <span className="font-semibold">{label}</span>
        <span style={{ color: 'var(--color-text-secondary)' }}>{limit > 0 ? `${used} of ${limit} ${unit}` : `${used} ${unit} used`}</span>
      </div>
      {limit > 0 && (
        <div role="progressbar" aria-label={`${label} used`} aria-valuemin={0} aria-valuemax={limit} aria-valuenow={Math.min(used, limit)} className="mt-2 h-2 overflow-hidden rounded-full" style={{ backgroundColor: 'var(--color-fill)' }}>
          <div className="h-full rounded-full" style={{ width: `${Math.round(fraction * 100)}%`, backgroundColor: near ? 'var(--color-text)' : 'var(--color-accent)' }} />
        </div>
      )}
      {near && <p className="mt-1.5 text-xs" style={{ color: 'var(--color-text-secondary)' }}>{fraction >= 1 ? 'Limit reached. New work waits until the reset.' : 'Close to this month’s limit.'}</p>}
    </div>
  );
}
