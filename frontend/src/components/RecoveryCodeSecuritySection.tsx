import { useEffect, useState } from 'react';
import { Check, Copy, Download, KeyRound, RotateCcw } from 'lucide-react';
import { SettingsCard } from './settings/SettingsCard';
import { Button } from './ui/Button';
import { Dialog } from './ui/Dialog';
import { Notice } from './ui/Field';
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
      <SettingsCard
        title="Recovery codes"
        description={<>
          <p>One-time codes to sign in if a passkey or password is unavailable. Keep them somewhere private.</p>
          <p className="mt-1 font-semibold text-text">{loading ? 'Checking recovery codes…' : remaining === null ? 'Recovery-code status unavailable' : `${remaining} unused ${remaining === 1 ? 'code' : 'codes'} left`}</p>
          {error && !rotation && <p className="mt-1 text-text" role="alert">{error}</p>}
        </>}
        action={(
          <div className="flex flex-col gap-2 sm:flex-row">
            {error && !rotation && <Button onClick={() => void load()}>Retry</Button>}
            <Button onClick={() => void start()} disabled={loading} busy={starting} icon={<RotateCcw className="h-4 w-4" />}>{starting ? 'Creating…' : remaining ? 'Replace codes' : 'Create codes'}</Button>
          </div>
        )}
      />

      <Dialog
        open={Boolean(rotation)}
        onClose={cancel}
        size="lg"
        title="Save your new recovery codes"
        footer={(
          <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <Button onClick={cancel} disabled={confirming}>Cancel and keep current codes</Button>
            <Button variant="primary" onClick={() => void confirm()} disabled={!saved} busy={confirming} icon={<KeyRound className="h-4 w-4" />}>{confirming ? 'Activating…' : 'Activate saved codes'}</Button>
          </div>
        )}
      >
        {rotation && (
          <>
            <p className="text-callout text-text-secondary">Your current codes still work. They are replaced only after you confirm this new set is saved.</p>
            <ol className="mt-4 grid gap-1 rounded-md bg-fill p-3 sm:grid-cols-2">
              {rotation.codes.map((code, index) => <li key={code} className="flex min-h-10 items-center gap-3 rounded-sm px-2 font-mono text-callout"><span className="w-5 text-right text-text-secondary tabular">{index + 1}</span><span className="select-all break-all">{code}</span></li>)}
            </ol>
            <div className="mt-3 grid gap-2 sm:grid-cols-2">
              <Button onClick={() => void copy()} icon={copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}>{copied ? 'Copied' : 'Copy all codes'}</Button>
              <Button onClick={download} icon={<Download className="h-4 w-4" />}>Download text file</Button>
            </div>
            <label className="mt-4 flex cursor-pointer items-start gap-3 rounded-md border border-separator p-3">
              <input type="checkbox" checked={saved} onChange={(event) => setSaved(event.target.checked)} className="mt-0.5 h-5 w-5" />
              <span><span className="block text-callout font-semibold">I saved these codes somewhere private</span><span className="mt-0.5 block text-meta text-text-secondary">Activating this set permanently replaces your current recovery codes.</span></span>
            </label>
            {error && <div className="mt-3"><Notice tone="error">{error}</Notice></div>}
          </>
        )}
      </Dialog>
    </>
  );
}

function messageFor(caught: unknown, fallback: string): string {
  return caught instanceof RecoveryCodeError ? caught.message : fallback;
}
