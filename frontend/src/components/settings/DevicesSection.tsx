import { useCallback, useEffect, useState } from 'react';
import { Laptop, Loader2, Smartphone } from 'lucide-react';
import { AccountAuthError, listDevices, revokeDevice, type DeviceSession } from '../../lib/accountAuth';
import { relativeTime } from '../../lib/relativeTime';
import { SecondaryButton } from '../auth/fields';
import { SettingsCard } from './SettingsCard';

function deviceLabel(session: DeviceSession): string {
  if (session.device_name) return session.device_name;
  return session.client_type === 'ios' ? 'iPhone or iPad' : session.client_type === 'android' ? 'Android device' : 'Web browser';
}

export function DevicesSection() {
  const [devices, setDevices] = useState<DeviceSession[] | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [confirming, setConfirming] = useState('');
  const [revoking, setRevoking] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      setDevices(await listDevices());
    } catch (caught) {
      setError(caught instanceof AccountAuthError ? caught.message : 'Could not load your devices.');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const revoke = async (id: string) => {
    setRevoking(id);
    setError('');
    try {
      await revokeDevice(id);
      setConfirming('');
      setDevices((current) => current?.filter((device) => device.id !== id) ?? current);
    } catch (caught) {
      setError(caught instanceof AccountAuthError ? caught.message : 'Could not sign that device out.');
    } finally {
      setRevoking('');
    }
  };

  return (
    <SettingsCard
      icon={<Laptop className="h-5 w-5" />}
      title="Signed-in devices"
      description="Each browser or phone signed in to your account. Signing one out ends its session right away. If it is the device you are using now, you will need to sign in again."
      action={error ? <SecondaryButton type="button" onClick={() => void load()}>Try again</SecondaryButton> : undefined}
    >
      {loading && !devices && <p className="flex items-center gap-2 text-sm" role="status" style={{ color: 'var(--color-text-secondary)' }}><Loader2 className="h-4 w-4 animate-spin" />Loading devices…</p>}
      {error && <p role="alert" className="mb-3 text-sm" style={{ color: 'var(--color-danger)' }}>{error}</p>}
      {devices && devices.length === 0 && <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>No other devices are signed in.</p>}
      {devices && devices.length > 0 && (
        <ul className="divide-y rounded-lg border" style={{ borderColor: 'var(--color-separator)' }}>
          {devices.map((device) => {
            const Icon = device.client_type === 'web' ? Laptop : Smartphone;
            const asking = confirming === device.id;
            return (
              <li key={device.id} className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between" style={{ borderColor: 'var(--color-separator)' }}>
                <div className="flex min-w-0 items-center gap-3">
                  <Icon className="h-5 w-5 shrink-0" style={{ color: 'var(--color-text-secondary)' }} />
                  <div className="min-w-0">
                    <p className="truncate text-sm font-semibold">{deviceLabel(device)}</p>
                    <p className="text-xs" style={{ color: 'var(--color-text-secondary)' }}>Last active {relativeTime(device.last_used_at) || 'recently'}</p>
                  </div>
                </div>
                {asking ? (
                  <div className="flex gap-2">
                    <SecondaryButton type="button" onClick={() => setConfirming('')} disabled={revoking === device.id}>Keep</SecondaryButton>
                    <button type="button" onClick={() => void revoke(device.id)} disabled={revoking === device.id} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-md px-4 text-sm font-semibold disabled:opacity-60" style={{ backgroundColor: 'var(--color-danger)', color: 'var(--color-on-accent)' }}>
                      {revoking === device.id && <Loader2 className="h-4 w-4 animate-spin" />}Sign out
                    </button>
                  </div>
                ) : (
                  <SecondaryButton type="button" onClick={() => setConfirming(device.id)} aria-label={`Sign out ${deviceLabel(device)}`}>Sign out</SecondaryButton>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </SettingsCard>
  );
}
