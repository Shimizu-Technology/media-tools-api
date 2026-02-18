/**
 * AuthContext — provides a consistent auth interface whether Clerk is enabled or not.
 *
 * Pattern from Brain Dump CLERK_AUTH_SETUP_GUIDE:
 * - Provides reactive isAuthenticated state for components
 * - Manages token getter for the API client
 * - Works with or without Clerk
 */
import { createContext, useContext } from 'react';
import type { ReactNode } from 'react';

interface AuthContextType {
  isClerkEnabled: boolean;
  isAuthenticated: boolean;
  isLoading: boolean;
}

const AuthContext = createContext<AuthContextType>({
  isClerkEnabled: false,
  isAuthenticated: false,
  isLoading: true,
});

export function useAuthContext() {
  return useContext(AuthContext);
}

interface AuthProviderProps {
  children: ReactNode;
  isClerkEnabled: boolean;
  isAuthenticated: boolean;
  isLoading: boolean;
}

/**
 * Generic auth provider — receives auth state from parent.
 * This decouples the context from Clerk hooks so it works outside ClerkProvider.
 */
export function AuthProvider({ children, isClerkEnabled, isAuthenticated, isLoading }: AuthProviderProps) {
  return (
    <AuthContext.Provider value={{ isClerkEnabled, isAuthenticated, isLoading }}>
      {children}
    </AuthContext.Provider>
  );
}
