import { useEffect, useState } from 'react';
import { Check, Copy, Download, KeyRound, Loader2, RotateCcw, ShieldCheck, X } from 'lucide-react';
import { beginRecoveryCodeRotation, confirmRecoveryCodeRotation, getRecoveryCodeStatus, RecoveryCodeError, type RecoveryRotation } from '../lib/recoveryCodes';

export function RecoveryCodeSecuritySection() {
  const [remaining, setRemaining] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [starting, setStarting] = useState(false);
  const [rotation, setRotation] = useState<RecoveryRotation | null>(null);
  const [saved, setSaved] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState('');

  const load = async () => {
    setLoading(true);
    setError('');
    try { setRemaining((await getRecoveryCodeStatus()).remaining); }
    catch (caught) { setError(messageFor(caught, 'Could not check your recovery codes.')); }
    finally { setLoading(false); }
  };

  useEffect(() => { void load(); }, []);

  const start = async () => {
    setStarting(true);
    setError('');
    try {
      setRotation(await beginRecoveryCodeRotation());
      setSaved(false);
      setCopied(false);
    } catch (caught) { setError(messageFor(caught, 'Could not create recovery codes.')); }
    finally { setStarting(false); }
  };

  const confirm = async () => {
    if (!rotation || !saved) return;
    setConfirming(true);
    setError('');
    try {
      setRemaining(await confirmRecoveryCodeRotation(rotation.rotation_id));
      setRotation(null);
      setSaved(false);
    } catch (caught) { setError(messageFor(caught, 'Could not activate these recovery codes.')); }
    finally { setConfirming(false); }
  };

  const copy = async () => {
    if (!rotation) return;
    try {
      await navigator.clipboard.writeText(rotation.codes.join('\n'));
      setCopied(true);
      setTimeout(() => setCopied(false), 3000);
    } catch { setError('Could not copy the codes. Select and save them manually.'); }
  };

  const download = () => {
    if (!rotation) return;
    const blob = new Blob([`Media Tools recovery codes\n\n${rotation.codes.join('\n')}\n\nEach code works once. Store this file somewhere private.\n`], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'media-tools-recovery-codes.txt';
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  };

  const cancel = () => {
    if (confirming) return;
    setRotation(null);
    setSaved(false);
    setCopied(false);
    setError('');
  };

  return (
    <>
      <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div className="flex items-start gap-4">
            <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}><ShieldCheck className="h-5 w-5" /></div>
            <div>
              <h2 className="text-xl font-semibold">Recovery codes</h2>
              <p className="mt-2 max-w-xl text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>Save these one-time codes somewhere private so you can sign in if a passkey is unavailable.</p>
              <p className="mt-2 text-sm font-semibold" style={{ color: remaining && remaining > 0 ? 'var(--color-success)' : 'var(--color-text-secondary)' }}>{loading ? 'Checking recovery codes…' : remaining === null ? 'Recovery-code status unavailable' : `${remaining} unused ${remaining === 1 ? 'code' : 'codes'} remaining`}</p>
              {error && !rotation && <p className="mt-2 text-sm" role="alert" style={{ color: 'var(--color-danger)' }}>{error}</p>}
            </div>
          </div>
          <div className="flex shrink-0 flex-col gap-2 sm:flex-row">
            {error && !rotation && <button type="button" onClick={() => void load()} className="min-h-11 rounded-xl border px-4 text-sm font-semibold" style={{ borderColor: 'var(--color-border)' }}>Retry</button>}
            <button type="button" onClick={() => void start()} disabled={loading || starting} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-4 text-sm font-semibold text-white disabled:opacity-60" style={{ backgroundColor: 'var(--color-brand-500)' }}>{starting ? <Loader2 className="h-4 w-4 animate-spin" /> : <RotateCcw className="h-4 w-4" />}{starting ? 'Creating…' : remaining ? 'Replace codes' : 'Create codes'}</button>
          </div>
        </div>
      </section>

      {rotation && (
        <div className="fixed inset-0 z-[100] flex items-center justify-center overflow-y-auto bg-black/70 p-4" role="presentation">
          <section role="dialog" aria-modal="true" aria-labelledby="recovery-codes-title" className="my-auto max-h-[calc(100dvh-2rem)] w-full max-w-2xl overflow-y-auto rounded-[2rem] border p-6 shadow-2xl sm:p-8" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
            <div className="flex items-start justify-between gap-4">
              <div><p className="text-xs font-semibold uppercase tracking-[0.2em]" style={{ color: 'var(--color-brand-500)' }}>One-time security step</p><h2 id="recovery-codes-title" className="mt-2 text-2xl font-semibold tracking-tight">Save your new recovery codes</h2></div>
              <button type="button" onClick={cancel} disabled={confirming} aria-label="Cancel and keep current recovery codes" className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl transition hover:bg-[var(--color-nav-hover)] disabled:opacity-50"><X className="h-5 w-5" /></button>
            </div>
            <p className="mt-3 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>Your current codes still work. They will be replaced only after you confirm that this new set is saved.</p>
            <ol className="mt-5 grid gap-2 rounded-2xl border p-4 sm:grid-cols-2" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-subtle)' }}>
              {rotation.codes.map((code, index) => <li key={code} className="flex min-h-10 items-center gap-3 rounded-lg px-2 font-mono text-xs sm:text-sm"><span className="w-5 text-right" style={{ color: 'var(--color-text-muted)' }}>{index + 1}</span><span className="break-all select-all">{code}</span></li>)}
            </ol>
            <div className="mt-4 grid gap-3 sm:grid-cols-2">
              <button type="button" onClick={() => void copy()} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border px-4 text-sm font-semibold" style={{ borderColor: 'var(--color-border)' }}>{copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}{copied ? 'Copied' : 'Copy all codes'}</button>
              <button type="button" onClick={download} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border px-4 text-sm font-semibold" style={{ borderColor: 'var(--color-border)' }}><Download className="h-4 w-4" />Download text file</button>
            </div>
            <label className="mt-5 flex cursor-pointer items-start gap-3 rounded-2xl border p-4" style={{ borderColor: saved ? 'var(--color-brand-500)' : 'var(--color-border)' }}>
              <input type="checkbox" checked={saved} onChange={(event) => setSaved(event.target.checked)} className="mt-1 h-5 w-5 accent-[var(--color-brand-500)]" />
              <span><span className="block text-sm font-semibold">I saved these codes somewhere private</span><span className="mt-1 block text-xs leading-5" style={{ color: 'var(--color-text-secondary)' }}>Activating this set permanently replaces your current recovery codes.</span></span>
            </label>
            {error && <p className="mt-3 text-sm" role="alert" style={{ color: 'var(--color-danger)' }}>{error}</p>}
            <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
              <button type="button" onClick={cancel} disabled={confirming} className="min-h-11 rounded-xl border px-5 text-sm font-semibold disabled:opacity-50" style={{ borderColor: 'var(--color-border)' }}>Cancel and keep current codes</button>
              <button type="button" onClick={() => void confirm()} disabled={!saved || confirming} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-5 text-sm font-semibold text-white disabled:opacity-50" style={{ backgroundColor: 'var(--color-brand-500)' }}>{confirming ? <Loader2 className="h-4 w-4 animate-spin" /> : <KeyRound className="h-4 w-4" />}{confirming ? 'Activating…' : 'Activate saved codes'}</button>
            </div>
          </section>
        </div>
      )}
    </>
  );
}

function messageFor(caught: unknown, fallback: string): string {
  return caught instanceof RecoveryCodeError ? caught.message : fallback;
}
