import { useContext } from 'react';
import { AuthContext } from './authContextValue';

export function useAuthContext() {
  return useContext(AuthContext);
}
