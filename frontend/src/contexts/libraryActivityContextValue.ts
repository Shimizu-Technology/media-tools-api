import { createContext } from 'react';
import type { LibraryItem } from '../lib/api';

export type LibraryActivityContextValue = {
  activeItems: LibraryItem[];
  activeJobCount: number;
  isLoading: boolean;
  error: string;
  refresh: (showLoading?: boolean) => Promise<void>;
};

export const LibraryActivityContext = createContext<LibraryActivityContextValue | null>(null);
