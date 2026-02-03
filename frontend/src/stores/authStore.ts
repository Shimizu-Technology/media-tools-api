/**
 * Auth store using Zustand (MTA-20).
 * Manages JWT token, user state, and auth persistence via localStorage.
 * Includes automatic token refresh to maintain sessions.
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
  refreshToken: () => Promise<boolean>;
  startTokenRefresh: () => void;
  stopTokenRefresh: () => void;
}

const TOKEN_KEY = 'mta_jwt_token';
const REFRESH_INTERVAL_MS = 60 * 60 * 1000; // Refresh every hour

let refreshIntervalId: ReturnType<typeof setInterval> | null = null;

export const useAuthStore = create<AuthState>((set, get) => ({
  token: null,
  user: null,
  isAuthenticated: false,
  isLoading: true,

  login: (token: string, user: User) => {
    localStorage.setItem(TOKEN_KEY, token);
    set({ token, user, isAuthenticated: true });
    // Start token refresh when logging in
    get().startTokenRefresh();
  },

  logout: () => {
    get().stopTokenRefresh();
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
        // Start token refresh for existing sessions
        get().startTokenRefresh();
      } else {
        // Token expired or invalid
        localStorage.removeItem(TOKEN_KEY);
        set({ isLoading: false });
      }
    } catch {
      set({ isLoading: false });
    }
  },

  refreshToken: async () => {
    const currentToken = get().token || localStorage.getItem(TOKEN_KEY);
    if (!currentToken) return false;

    try {
      const res = await fetch('/api/v1/auth/refresh', {
        method: 'POST',
        headers: { 
          'Content-Type': 'application/json',
          Authorization: `Bearer ${currentToken}`,
        },
      });

      if (res.ok) {
        const data = await res.json();
        localStorage.setItem(TOKEN_KEY, data.token);
        set({ token: data.token, user: data.user });
        return true;
      } else {
        // Token invalid or expired — logout
        get().logout();
        return false;
      }
    } catch {
      // Network error — don't logout, just return false
      return false;
    }
  },

  startTokenRefresh: () => {
    // Clear any existing interval
    if (refreshIntervalId) {
      clearInterval(refreshIntervalId);
    }
    // Set up periodic refresh
    refreshIntervalId = setInterval(() => {
      get().refreshToken();
    }, REFRESH_INTERVAL_MS);
  },

  stopTokenRefresh: () => {
    if (refreshIntervalId) {
      clearInterval(refreshIntervalId);
      refreshIntervalId = null;
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
