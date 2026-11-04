import { createContext } from 'react';

import type { User } from '../lib/api';
import type { SessionPhase } from '../lib/webSession';

interface AuthContextType {
  /** False only in local API-key development mode, which production builds exclude. */
  accountAuthEnabled: boolean;
  phase: SessionPhase;
  isAuthenticated: boolean;
  isLoading: boolean;
  /** The session could not be checked (offline or server trouble); it is not signed out. */
  isUnavailable: boolean;
  canUseWorkspace: boolean;
  user: User | null;
  refreshUser: () => Promise<void>;
  /** Re-ask the server about the session after an outage. */
  retrySession: () => Promise<void>;
  signOut: () => Promise<void>;
}

export const AuthContext = createContext<AuthContextType>({
  accountAuthEnabled: false,
  phase: 'checking',
  isAuthenticated: false,
  isLoading: true,
  isUnavailable: false,
  canUseWorkspace: false,
  user: null,
  refreshUser: async () => undefined,
  retrySession: async () => undefined,
  signOut: async () => undefined,
});
