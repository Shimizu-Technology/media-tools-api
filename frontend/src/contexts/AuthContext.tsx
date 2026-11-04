/**
 * AuthContext — reactive account state for components.
 *
 * App owns the browser-session lifecycle and passes the result in, so this
 * provider stays a plain container that is easy to render in tests.
 */
import type { ReactNode } from 'react';
import type { User } from '../lib/api';
import type { SessionPhase } from '../lib/webSession';
import { AuthContext } from './authContextValue';

interface AuthProviderProps {
  children: ReactNode;
  accountAuthEnabled: boolean;
  phase?: SessionPhase;
  isAuthenticated: boolean;
  isLoading: boolean;
  canUseWorkspace: boolean;
  user?: User | null;
  refreshUser?: () => Promise<void>;
  retrySession?: () => Promise<void>;
  signOut?: () => Promise<void>;
}

export function AuthProvider({
  children,
  accountAuthEnabled,
  phase = 'checking',
  isAuthenticated,
  isLoading,
  canUseWorkspace,
  user = null,
  refreshUser = async () => undefined,
  retrySession = async () => undefined,
  signOut = async () => undefined,
}: AuthProviderProps) {
  return (
    <AuthContext.Provider value={{ accountAuthEnabled, phase, isAuthenticated, isLoading, isUnavailable: phase === 'unavailable', canUseWorkspace, user, refreshUser, retrySession, signOut }}>
      {children}
    </AuthContext.Provider>
  );
}
