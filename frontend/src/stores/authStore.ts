/**
 * Auth store using Zustand (MTA-20).
 * Manages JWT token, user state, and auth persistence via localStorage.
 */
import { create } from 'zustand';

export interface User {
  id: string;
  email: string;
  name: string;
  created_at: string;
}

interface AuthState {
  token: string | null;
  user: User | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  login: (token: string, user: User) => void;
  logout: () => void;
  setLoading: (loading: boolean) => void;
  initialize: () => Promise<void>;
}

const TOKEN_KEY = 'mta_jwt_token';

export const useAuthStore = create<AuthState>((set, _get) => ({
  token: null,
  user: null,
  isAuthenticated: false,
  isLoading: true,

  login: (token: string, user: User) => {
    localStorage.setItem(TOKEN_KEY, token);
    set({ token, user, isAuthenticated: true });
  },

  logout: () => {
    localStorage.removeItem(TOKEN_KEY);
    set({ token: null, user: null, isAuthenticated: false });
  },

  setLoading: (loading: boolean) => set({ isLoading: loading }),

  initialize: async () => {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token) {
      set({ isLoading: false });
      return;
    }

    try {
      const res = await fetch('/api/v1/auth/me', {
        headers: { Authorization: `Bearer ${token}` },
      });

      if (res.ok) {
        const user: User = await res.json();
        set({ token, user, isAuthenticated: true, isLoading: false });
      } else {
        // Token expired or invalid
        localStorage.removeItem(TOKEN_KEY);
        set({ isLoading: false });
      }
    } catch {
      set({ isLoading: false });
    }
  },
}));

/**
 * Get auth headers — returns JWT Bearer token if logged in,
 * otherwise falls back to API key from localStorage.
 */
export function getAuthHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };

  const token = localStorage.getItem(TOKEN_KEY);
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
    return headers;
  }

  // Fallback to API key
  const apiKey = localStorage.getItem('mta_api_key');
  if (apiKey) {
    headers['X-API-Key'] = apiKey;
  }

  return headers;
}

/**
 * Get headers for file uploads (no Content-Type, let browser set it).
 */
export function getAuthUploadHeaders(): Record<string, string> {
  const headers: Record<string, string> = {};

  const token = localStorage.getItem(TOKEN_KEY);
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
    return headers;
  }

  const apiKey = localStorage.getItem('mta_api_key');
  if (apiKey) {
    headers['X-API-Key'] = apiKey;
  }

  return headers;
}
