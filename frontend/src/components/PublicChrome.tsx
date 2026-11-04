import { Link } from 'react-router-dom';
import { useAuthContext } from '../contexts/useAuthContext';
import { Mark } from './ui/Mark';
import { buttonClass } from './ui/styles';

/** The public bar: the name, two plain links, one action. */
export function PublicHeader() {
  const { accountAuthEnabled, isAuthenticated } = useAuthContext();
  const action = isAuthenticated || !accountAuthEnabled
    ? { to: '/app', label: 'Open Media Tools' }
    : { to: '/sign-in', label: 'Sign in' };
  return (
    <header className="bg-background pt-[env(safe-area-inset-top)]">
      <div className="mx-auto flex h-16 max-w-6xl items-center gap-2 px-[max(1rem,env(safe-area-inset-left))] sm:px-8">
        <Link to="/" className="-ml-1 flex min-h-11 items-center gap-2.5 rounded-md px-1">
          <Mark size={30} />
          <span className="font-display text-lg font-extrabold tracking-[-0.01em]">Media Tools</span>
        </Link>
        <div className="flex-1" />
        <nav aria-label="Site" className="hidden items-center sm:flex">
          <Link to="/docs" className="inline-flex min-h-11 items-center rounded-md px-3 text-callout font-medium text-text-secondary hover:text-text">API</Link>
          <Link to="/privacy" className="inline-flex min-h-11 items-center rounded-md px-3 text-callout font-medium text-text-secondary hover:text-text">Privacy</Link>
        </nav>
        <Link to={action.to} className={buttonClass({ variant: 'primary', className: 'rounded-full' })}>{action.label}</Link>
      </div>
    </header>
  );
}

/** A designed close: the name again, then the links people look for. */
export function PublicFooter() {
  return (
    <footer className="bg-surface pb-[max(2rem,env(safe-area-inset-bottom))] pt-14">
      <div className="mx-auto max-w-6xl px-4 sm:px-8">
        <p className="font-display text-[clamp(2.5rem,8vw,5.5rem)] font-extrabold leading-none tracking-[-0.03em]">Media Tools</p>
        <nav aria-label="Legal and help" className="mt-8 flex flex-wrap gap-x-1 text-callout">
          {[
            ['/privacy', 'Privacy'],
            ['/terms', 'Terms'],
            ['/support', 'Support'],
            ['/delete-account', 'Delete your account'],
            ['/docs', 'API'],
          ].map(([to, label]) => (
            <Link key={to} to={to} className="-ml-2 inline-flex min-h-11 items-center px-2 font-medium text-text-secondary hover:text-text">{label}</Link>
          ))}
        </nav>
        <p className="mt-4 text-meta text-text-secondary">
          Made by <a href="https://github.com/Shimizu-Technology" target="_blank" rel="noopener noreferrer" className="font-medium text-text-secondary underline hover:text-text">Shimizu Technology</a>.
        </p>
      </div>
    </footer>
  );
}
