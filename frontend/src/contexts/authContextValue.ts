import { createContext } from 'react';

import type { User } from '../lib/api';

interface AuthContextType {
  isClerkEnabled: boolean;
  isAuthenticated: boolean;
  isLoading: boolean;
  canUseWorkspace: boolean;
  user: User | null;
  refreshUser: () => Promise<void>;
}

export const AuthContext = createContext<AuthContextType>({
  isClerkEnabled: false,
  isAuthenticated: false,
  isLoading: true,
  canUseWorkspace: false,
  user: null,
  refreshUser: async () => undefined,
});
