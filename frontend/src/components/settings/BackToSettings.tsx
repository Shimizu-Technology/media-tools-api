import { Link } from 'react-router-dom';
import { ChevronLeft } from 'lucide-react';

export function BackToSettings() {
  return (
    <Link to="/app/settings" className="pressable -ml-2 inline-flex min-h-11 items-center gap-0.5 rounded-md pr-3 text-body text-accent-text hover:bg-fill">
      <ChevronLeft className="h-6 w-6" aria-hidden="true" />Settings
    </Link>
  );
}
