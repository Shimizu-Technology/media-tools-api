import { createContext } from 'react';

interface AuthContextType {
  isClerkEnabled: boolean;
  isAuthenticated: boolean;
  isLoading: boolean;
  canUseWorkspace: boolean;
}

export const AuthContext = createContext<AuthContextType>({
  isClerkEnabled: false,
  isAuthenticated: false,
  isLoading: true,
  canUseWorkspace: false,
});
