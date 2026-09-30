import { createContext } from 'react';

import type { User } from '../lib/api';

interface AuthContextType {
  isClerkEnabled: boolean;
  accountAuthEnabled: boolean;
  isFirstPartySession: boolean;
  isPreviousProviderSignedIn: boolean;
  isAuthenticated: boolean;
  isLoading: boolean;
  canUseWorkspace: boolean;
  user: User | null;
  refreshUser: () => Promise<void>;
  signOut: () => Promise<void>;
  leavePreviousProviderForOnboarding: () => Promise<void>;
}

export const AuthContext = createContext<AuthContextType>({
  isClerkEnabled: false,
  accountAuthEnabled: false,
  isFirstPartySession: false,
  isPreviousProviderSignedIn: false,
  isAuthenticated: false,
  isLoading: true,
  canUseWorkspace: false,
  user: null,
  refreshUser: async () => undefined,
  signOut: async () => undefined,
  leavePreviousProviderForOnboarding: async () => undefined,
});
