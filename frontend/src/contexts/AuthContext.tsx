/**
 * AuthContext — provides a consistent auth interface whether Clerk is enabled or not.
 *
 * Pattern from Brain Dump CLERK_AUTH_SETUP_GUIDE:
 * - Provides reactive isAuthenticated state for components
 * - Manages token getter for the API client
 * - Works with or without Clerk
 */
import type { ReactNode } from 'react';
import type { User } from '../lib/api';
import { AuthContext } from './authContextValue';

interface AuthProviderProps {
  children: ReactNode;
  isClerkEnabled: boolean;
  isAuthenticated: boolean;
  isLoading: boolean;
  canUseWorkspace: boolean;
  user?: User | null;
  refreshUser?: () => Promise<void>;
}

/**
 * Generic auth provider — receives auth state from parent.
 * This decouples the context from Clerk hooks so it works outside ClerkProvider.
 */
export function AuthProvider({
  children,
  isClerkEnabled,
  isAuthenticated,
  isLoading,
  canUseWorkspace,
  user = null,
  refreshUser = async () => undefined,
}: AuthProviderProps) {
  return (
    <AuthContext.Provider value={{ isClerkEnabled, isAuthenticated, isLoading, canUseWorkspace, user, refreshUser }}>
      {children}
    </AuthContext.Provider>
  );
}
