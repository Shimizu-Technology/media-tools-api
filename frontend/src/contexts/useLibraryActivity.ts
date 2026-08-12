import { useContext } from 'react';
import { LibraryActivityContext } from './libraryActivityContextValue';

export function useLibraryActivity() {
  const value = useContext(LibraryActivityContext);
  if (!value) throw new Error('useLibraryActivity must be used inside LibraryActivityProvider');
  return value;
}
