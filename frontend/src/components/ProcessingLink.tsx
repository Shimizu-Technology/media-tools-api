import { Link } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import { useLibraryActivity } from '../contexts/useLibraryActivity';
import { APP_ROUTES } from '../lib/appRoutes';

/** How many items are moving, linking to them. Nothing when nothing is. */
export function ProcessingLink({ className = '' }: { className?: string }) {
  const { activeJobCount } = useLibraryActivity();
  if (activeJobCount === 0) return null;
  return (
    <Link to={`${APP_ROUTES.library}?status=active`} className={`inline-flex min-h-11 items-center gap-1.5 whitespace-nowrap rounded-full px-3 text-meta font-semibold text-text-secondary hover:bg-fill ${className}`}>
      <Loader2 className="h-3.5 w-3.5 animate-spin text-accent-text" aria-hidden="true" />
      <span><span className="font-mono">{activeJobCount.toLocaleString()}</span> processing</span>
    </Link>
  );
}
