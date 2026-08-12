import { useContext } from 'react';
import { LibraryActivityContext } from './libraryActivityContextValue';

/** Returns the shared active-job snapshot and refresh controls for signed-in app routes. */
export function useLibraryActivity() {
  const value = useContext(LibraryActivityContext);
  if (!value) throw new Error('useLibraryActivity must be used inside LibraryActivityProvider');
  return value;
}
