import { create } from 'zustand';
import { persist } from 'zustand/middleware';

/**
 * Zustand holds client-only UI state. Server data (users, notes, anything from
 * /api) lives in TanStack Query and is never copied here.
 * Never store tokens, secrets, MFA codes, or PII in a store or in localStorage.
 */
type Theme = 'light' | 'dark' | 'system';

interface UiState {
  sidebarOpen: boolean;
  theme: Theme;
  toggleSidebar: () => void;
  setTheme: (theme: Theme) => void;
}

export const useUiStore = create<UiState>()(
  persist(
    (set) => ({
      sidebarOpen: true,
      theme: 'system',
      toggleSidebar: () => set((s) => ({ sidebarOpen: !s.sidebarOpen })),
      setTheme: (theme) => set({ theme }),
    }),
    { name: 'ui', partialize: (s) => ({ theme: s.theme }) },
  ),
);
