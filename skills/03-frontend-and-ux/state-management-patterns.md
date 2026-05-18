---
name: State Management Patterns
slug: state-management-patterns
category: 03-frontend-and-ux
proficiency: advanced
description: >
  Design and implement client-side state management for complex React
  applications. Covers the state taxonomy (local/server/URL/global),
  Zustand for global UI state, TanStack Query for server state, URL
  state for shareable views, optimistic updates, derived state, and
  patterns for avoiding over-fetching and unnecessary re-renders.
tags:
  - state-management
  - zustand
  - tanstack-query
  - react-query
  - server-state
  - optimistic-updates
  - derived-state
  - react
  - context-api
status: published
---

## Principles

### State Taxonomy — The Most Important Concept
Before choosing a library, classify what kind of state you have:

| Type | Definition | Right Tool |
|------|-----------|-----------|
| **Local UI state** | Belongs to one component (open/closed, input value) | `useState`, `useReducer` |
| **Shared UI state** | Belongs to multiple components (theme, modal state, sidebar) | Zustand, Context |
| **Server state** | Data from the API; has async lifecycle (loading/error/stale) | TanStack Query, SWR |
| **URL state** | Filter/pagination/tab state that should be bookmarkable | `useSearchParams`, URL routing |
| **Form state** | Input values, validation errors, touched fields | React Hook Form, Formik |

The most common mistake: treating **server state as global UI state** — storing API data in Redux/Zustand and manually managing loading/error/refetch lifecycle.

### The Server State Problem
Server state is fundamentally different from UI state:
- It's remote (network latency, failures)
- It can change without your knowledge (stale data)
- It's shared with other users (concurrent updates)
- It has async lifecycle (loading, error, success, refetching)

Trying to manage this with `useState` + `useEffect` leads to:
- Duplicate requests across components
- No automatic refetching when the window regains focus
- Manual loading/error/empty state management everywhere
- No background cache invalidation

**TanStack Query** solves all of this. Zustand/Redux should never hold server data.

### When You Don't Need a State Library
- Small app (< 10 pages, single developer): `useState` + `useContext` is sufficient
- Server-rendered app with minimal client interaction: next to no client state needed
- You only have server data: TanStack Query alone covers you; no global store needed

---

## Implementation Patterns

### Pattern 1 — Zustand Global UI Store
```typescript
// src/stores/app-store.ts — global UI state only (never server data)

import { create } from 'zustand';
import { devtools, persist } from 'zustand/middleware';
import { immer } from 'zustand/middleware/immer';

// ── Types ────────────────────────────────────────────────────────────────────

type Theme = 'light' | 'dark' | 'system';
type Sidebar = { isOpen: boolean; activeSection: string | null };

interface Notification {
  id: string;
  type: 'success' | 'error' | 'info' | 'warning';
  message: string;
  duration?: number;
}

interface AppState {
  // UI state
  theme: Theme;
  sidebar: Sidebar;
  notifications: Notification[];

  // Actions — co-located with state (Zustand convention)
  setTheme: (theme: Theme) => void;
  toggleSidebar: () => void;
  setSidebarSection: (section: string | null) => void;
  addNotification: (notification: Omit<Notification, 'id'>) => void;
  dismissNotification: (id: string) => void;
}

// ── Store ────────────────────────────────────────────────────────────────────

export const useAppStore = create<AppState>()(
  devtools(
    persist(
      immer((set) => ({
        // Initial state
        theme: 'system',
        sidebar: { isOpen: true, activeSection: null },
        notifications: [],

        // Actions — immer middleware allows direct mutation syntax
        setTheme: (theme) => set((state) => { state.theme = theme; }),

        toggleSidebar: () =>
          set((state) => { state.sidebar.isOpen = !state.sidebar.isOpen; }),

        setSidebarSection: (section) =>
          set((state) => { state.sidebar.activeSection = section; }),

        addNotification: (notification) =>
          set((state) => {
            state.notifications.push({
              id: crypto.randomUUID(),
              duration: 5000,
              ...notification,
            });
          }),

        dismissNotification: (id) =>
          set((state) => {
            state.notifications = state.notifications.filter((n) => n.id !== id);
          }),
      })),
      {
        name: 'app-ui-store',
        // Only persist theme preference, not transient UI state
        partialize: (state) => ({ theme: state.theme }),
      }
    ),
    { name: 'AppStore' }
  )
);

// ── Selector hooks — prevent unnecessary re-renders ──────────────────────────

// Components subscribe only to the slice they need
export const useTheme = () => useAppStore((s) => s.theme);
export const useSidebar = () => useAppStore((s) => s.sidebar);
export const useNotifications = () => useAppStore((s) => s.notifications);
export const useAppActions = () =>
  useAppStore((s) => ({
    setTheme: s.setTheme,
    toggleSidebar: s.toggleSidebar,
    setSidebarSection: s.setSidebarSection,
    addNotification: s.addNotification,
    dismissNotification: s.dismissNotification,
  }));
```

### Pattern 2 — TanStack Query Server State (Full Lifecycle)
```typescript
// src/api/payments.ts — query functions (pure, no state)

import { queryOptions, infiniteQueryOptions } from '@tanstack/react-query';

export interface Payment {
  id: string;
  accountId: string;
  amountCents: number;
  currency: string;
  status: 'pending' | 'captured' | 'failed';
  createdAt: string;
}

export interface PaymentsFilter {
  status?: Payment['status'];
  fromDate?: string;
  toDate?: string;
  search?: string;
}

const api = {
  getPayment: (id: string): Promise<Payment> =>
    fetch(`/api/payments/${id}`).then((r) => {
      if (!r.ok) throw new Error(`${r.status}: ${r.statusText}`);
      return r.json();
    }),

  listPayments: (filter: PaymentsFilter, page: number): Promise<{
    data: Payment[];
    nextCursor: string | null;
    total: number;
  }> =>
    fetch(`/api/payments?${new URLSearchParams({
      ...filter,
      page: String(page),
    })}`).then((r) => r.json()),

  createPayment: (payload: CreatePaymentPayload): Promise<Payment> =>
    fetch('/api/payments', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }).then((r) => r.json()),
};

// ── Query key factory — centralises key management ────────────────────────────

export const paymentKeys = {
  all:    ['payments']                                      as const,
  lists:  () => [...paymentKeys.all, 'list']               as const,
  list:   (filter: PaymentsFilter) => [...paymentKeys.lists(), filter] as const,
  detail: (id: string) => [...paymentKeys.all, 'detail', id] as const,
};

// ── Query options — reusable, shareable, type-safe ────────────────────────────

export const paymentDetailQuery = (id: string) =>
  queryOptions({
    queryKey: paymentKeys.detail(id),
    queryFn: () => api.getPayment(id),
    staleTime: 60 * 1000,          // data is fresh for 60s — no refetch needed
    gcTime: 5 * 60 * 1000,         // keep in cache 5min after last use
  });

export const paymentsListQuery = (filter: PaymentsFilter) =>
  queryOptions({
    queryKey: paymentKeys.list(filter),
    queryFn: ({ pageParam = 1 }) => api.listPayments(filter, pageParam as number),
    staleTime: 30 * 1000,
  });

// ─────────────────────────────────────────────────────────────────────────────

// src/hooks/usePayments.ts — query and mutation hooks

import { useQuery, useMutation, useQueryClient, useInfiniteQuery } from '@tanstack/react-query';

export function usePayment(id: string) {
  return useQuery(paymentDetailQuery(id));
}

export function usePaymentsList(filter: PaymentsFilter) {
  return useQuery(paymentsListQuery(filter));
}

// ── Optimistic update on mutation ────────────────────────────────────────────

export function useCapturePayment() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (paymentId: string) =>
      fetch(`/api/payments/${paymentId}/capture`, { method: 'POST' })
        .then((r) => r.json()),

    onMutate: async (paymentId: string) => {
      // Cancel any in-flight refetches that would overwrite the optimistic update
      await queryClient.cancelQueries({ queryKey: paymentKeys.detail(paymentId) });

      // Snapshot current value for rollback
      const previous = queryClient.getQueryData<Payment>(paymentKeys.detail(paymentId));

      // Optimistically update the cache
      queryClient.setQueryData<Payment>(paymentKeys.detail(paymentId), (old) =>
        old ? { ...old, status: 'captured' } : old
      );

      return { previous };
    },

    onError: (err, paymentId, context) => {
      // Rollback to snapshot on failure
      if (context?.previous) {
        queryClient.setQueryData(paymentKeys.detail(paymentId), context.previous);
      }
    },

    onSettled: (data, error, paymentId) => {
      // Always refetch after mutation — ensures cache is in sync with server
      queryClient.invalidateQueries({ queryKey: paymentKeys.detail(paymentId) });
      queryClient.invalidateQueries({ queryKey: paymentKeys.lists() });
    },
  });
}

// ── Create payment with cache update ─────────────────────────────────────────

export function useCreatePayment() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: api.createPayment,
    onSuccess: (newPayment) => {
      // Pre-populate the detail cache — avoids a network request when navigating to detail
      queryClient.setQueryData(paymentKeys.detail(newPayment.id), newPayment);
      // Invalidate lists so the new payment appears
      queryClient.invalidateQueries({ queryKey: paymentKeys.lists() });
    },
  });
}
```

### Pattern 3 — URL State for Filters and Pagination
```typescript
// src/hooks/usePaymentFilters.ts
// Filters live in the URL — shareable, bookmarkable, survives refresh

import { useSearchParams } from 'react-router-dom';
import { useCallback, useMemo } from 'react';

interface PaymentFilters {
  status?: 'pending' | 'captured' | 'failed';
  search?: string;
  fromDate?: string;
  toDate?: string;
  page: number;
}

export function usePaymentFilters() {
  const [searchParams, setSearchParams] = useSearchParams();

  const filters = useMemo((): PaymentFilters => ({
    status:   (searchParams.get('status') as PaymentFilters['status']) ?? undefined,
    search:   searchParams.get('search') ?? undefined,
    fromDate: searchParams.get('from') ?? undefined,
    toDate:   searchParams.get('to') ?? undefined,
    page:     Number(searchParams.get('page') ?? '1'),
  }), [searchParams]);

  const setFilters = useCallback(
    (updates: Partial<PaymentFilters>) => {
      setSearchParams((prev) => {
        const next = new URLSearchParams(prev);
        Object.entries(updates).forEach(([key, value]) => {
          const paramKey = key === 'fromDate' ? 'from' : key === 'toDate' ? 'to' : key;
          if (value === undefined || value === null || value === '') {
            next.delete(paramKey);
          } else {
            next.set(paramKey, String(value));
          }
        });
        // Reset to page 1 when filter changes (not when page itself changes)
        if (!('page' in updates)) {
          next.set('page', '1');
        }
        return next;
      }, { replace: true }); // replace to avoid back-button pollution
    },
    [setSearchParams]
  );

  const resetFilters = useCallback(() => {
    setSearchParams({}, { replace: true });
  }, [setSearchParams]);

  return { filters, setFilters, resetFilters };
}

// ─── Usage ────────────────────────────────────────────────────────────────────

function PaymentsList() {
  const { filters, setFilters } = usePaymentFilters();
  const { data, isLoading } = usePaymentsList(filters);

  return (
    <div>
      <StatusFilter
        value={filters.status}
        onChange={(status) => setFilters({ status })}
      />
      <SearchInput
        value={filters.search ?? ''}
        onChange={(search) => setFilters({ search })}
      />
      {isLoading ? <Skeleton /> : <PaymentsTable data={data?.data ?? []} />}
      <Pagination
        page={filters.page}
        total={data?.total}
        onChange={(page) => setFilters({ page })}
      />
    </div>
  );
}
```

### Pattern 4 — Derived State and Selectors
```typescript
// Derive state instead of storing redundant state

// ── WRONG: storing derived data in state ──────────────────────────────────────

const [items, setItems] = useState<Item[]>([]);
const [total, setTotal] = useState(0);           // ← derived; keep in sync manually
const [filteredItems, setFilteredItems] = useState<Item[]>([]);  // ← derived

function addItem(item: Item) {
  setItems(prev => [...prev, item]);
  setTotal(prev => prev + item.price);           // easy to forget; gets out of sync
  setFilteredItems(current.filter(applyFilter)); // manual sync = bugs
}

// ── RIGHT: derive from single source of truth ─────────────────────────────────

const [items, setItems] = useState<Item[]>([]);
const [filter, setFilter] = useState<FilterState>({ search: '', minPrice: 0 });

// Derived — computed on every render (use useMemo if expensive)
const filteredItems = useMemo(
  () => items.filter((item) =>
    item.name.toLowerCase().includes(filter.search.toLowerCase()) &&
    item.price >= filter.minPrice
  ),
  [items, filter]
);

const total = filteredItems.reduce((sum, item) => sum + item.price, 0);

// ── Zustand selectors — compute derived state from store ──────────────────────

// In the store:
interface CartState {
  items: CartItem[];
  addItem: (item: CartItem) => void;
  removeItem: (id: string) => void;
}

export const useCartStore = create<CartState>()((set) => ({
  items: [],
  addItem: (item) => set((s) => ({ items: [...s.items, item] })),
  removeItem: (id) => set((s) => ({ items: s.items.filter((i) => i.id !== id) })),
}));

// Derived selectors — defined outside the store, memoized by Zustand's shallow equal
export const useCartTotal = () =>
  useCartStore((s) => s.items.reduce((sum, item) => sum + item.price * item.qty, 0));

export const useCartItemCount = () =>
  useCartStore((s) => s.items.reduce((count, item) => count + item.qty, 0));

export const useCartItemById = (id: string) =>
  useCartStore((s) => s.items.find((item) => item.id === id));
```

### Pattern 5 — React Query Client Configuration
```typescript
// src/lib/query-client.ts — global TanStack Query configuration

import { QueryClient, MutationCache, QueryCache } from '@tanstack/react-query';
import { toast } from 'sonner';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // Data is fresh for 30s — no refetch during this window
      staleTime: 30 * 1000,
      // Keep unused data in cache for 5 minutes
      gcTime: 5 * 60 * 1000,
      // Retry failed queries 2 times with exponential backoff
      retry: 2,
      retryDelay: (attempt) => Math.min(1000 * 2 ** attempt, 30_000),
      // Refetch when window regains focus (user returns to tab with fresh data)
      refetchOnWindowFocus: true,
      // Don't refetch on mount if data is still fresh
      refetchOnMount: true,
    },
    mutations: {
      retry: 0,  // don't auto-retry mutations — idempotency risk
    },
  },

  // Global error handling — fires for every failed query
  queryCache: new QueryCache({
    onError: (error, query) => {
      // Only show global error for background refetches (not initial load — handled locally)
      if (query.state.data !== undefined) {
        toast.error(`Failed to refresh: ${(error as Error).message}`);
      }
    },
  }),

  // Global mutation error handling
  mutationCache: new MutationCache({
    onError: (error, _variables, _context, mutation) => {
      // Only show toast if the mutation has no local onError handler
      if (!mutation.options.onError) {
        toast.error(`Action failed: ${(error as Error).message}`);
      }
    },
  }),
});

// ── Prefetch on hover ─────────────────────────────────────────────────────────

// Prefetch payment detail when user hovers over a list item
// Data is ready before they click — perceived instant navigation

export function usePaymentPrefetch() {
  const queryClient_ = useQueryClient();
  return useCallback(
    (paymentId: string) => {
      queryClient_.prefetchQuery(paymentDetailQuery(paymentId));
    },
    [queryClient_]
  );
}

// Usage in PaymentRow:
function PaymentRow({ payment }: { payment: Payment }) {
  const prefetch = usePaymentPrefetch();
  return (
    <tr
      onMouseEnter={() => prefetch(payment.id)}
      onFocus={() => prefetch(payment.id)}
    >
      ...
    </tr>
  );
}
```

### Pattern 6 — Context for Dependency Injection (Not State)
```typescript
// Use React Context for DI (passing services/config down), not for frequently
// changing state (causes unnecessary re-renders for all consumers)

// src/contexts/auth-context.tsx — stable auth session (changes rarely)

import { createContext, useContext, useState, useEffect, ReactNode } from 'react';

interface AuthUser {
  id: string;
  email: string;
  role: 'admin' | 'operator' | 'viewer';
}

interface AuthContextValue {
  user: AuthUser | null;
  isLoading: boolean;
  logout: () => void;
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<AuthUser | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    fetch('/api/me')
      .then((r) => (r.ok ? r.json() : null))
      .then((u) => {
        setUser(u);
        setIsLoading(false);
      })
      .catch(() => setIsLoading(false));
  }, []);

  const logout = async () => {
    await fetch('/api/logout', { method: 'POST' });
    setUser(null);
    queryClient.clear();  // clear all cached server data on logout
    window.location.href = '/login';
  };

  // Stable value — only re-renders consumers when user or isLoading changes (rare)
  const value: AuthContextValue = { user, isLoading, logout };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}

// ── What NOT to put in Context ────────────────────────────────────────────────

// WRONG: filter state in context — changes on every keystroke, re-renders all consumers
const FilterContext = createContext<FilterState>({});
// RIGHT: URL state (useSearchParams) or Zustand slice

// WRONG: server data in context
const PaymentsContext = createContext<Payment[]>([]);
// RIGHT: TanStack Query — usePaymentsList(filter)
```

---

## Anti-Patterns

### 1. Storing Server Data in Zustand/Redux
```typescript
// WRONG — manual async lifecycle, no caching, no background refetch
const usePaymentsStore = create((set) => ({
  payments: [],
  loading: false,
  error: null,
  fetchPayments: async () => {
    set({ loading: true });
    try {
      const data = await api.getPayments();
      set({ payments: data, loading: false });
    } catch (e) {
      set({ error: e, loading: false });
    }
  },
}));
```
**Fix**: TanStack Query. All the async lifecycle, caching, background refetch, and deduplication is handled automatically.

### 2. prop drilling vs the Wrong Tool
Lifting state to a common ancestor 5 levels above just to avoid adding a state library creates prop-drilling hell. But adding a global store for state that only two sibling components need is also wrong.

**Fix**: colocate state as close as possible. Use Context for subtree-scoped state. Use Zustand for genuinely global UI state.

### 3. Storing Derived State
```typescript
// WRONG — total is derived; keeping it in sync manually is error-prone
const [items, setItems] = useState([]);
const [total, setTotal] = useState(0);
```
**Fix**: compute derived state with `useMemo`. Only store primitive state; derive everything else.

### 4. Not Using Query Keys Correctly
```typescript
// WRONG — same query key for different filters; cache collision
useQuery({ queryKey: ['payments'], queryFn: () => api.getPayments(filter) });
```
**Fix**: include all variables that affect the query result in the key. Use a key factory: `paymentKeys.list(filter)`.

### 5. Calling `queryClient.invalidateQueries` Too Broadly
```typescript
// WRONG — invalidates everything, including unrelated queries
queryClient.invalidateQueries();
```
**Fix**: invalidate only the affected queries using specific keys: `queryClient.invalidateQueries({ queryKey: paymentKeys.lists() })`.

### 6. Re-render on Every Store Change
```typescript
// WRONG — subscribes to entire store; re-renders on any state change
const state = useAppStore(); // ← subscribes to ALL changes
const theme = state.theme;
```
**Fix**: use selector: `const theme = useAppStore((s) => s.theme)` — only re-renders when `theme` changes.

---

## Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| State used by one component | `useState` |
| State shared by 2–3 nearby components | Lift to common parent |
| Async data from API | TanStack Query |
| Filter/pagination/tab | URL state (`useSearchParams`) |
| Global UI preferences (theme, sidebar) | Zustand |
| Auth session | React Context (changes rarely) |
| Complex local form state | React Hook Form |
| Data needed across disconnected subtrees | Zustand or TanStack Query |
| State that should survive navigation | URL state or persisted Zustand |
| Real-time data (WebSocket) | TanStack Query + `queryClient.setQueryData` on WS message |

---

## Proficiency Levels

### Novice
- Uses `useState` and `useContext` correctly
- Understands lifting state to a common parent
- Can fetch data with `useEffect` + `useState` (but knows TanStack Query is better)

### Intermediate
- Uses TanStack Query for all server state; no async lifecycle in Zustand/Redux
- Uses URL state for filters and pagination
- Writes Zustand stores with actions co-located; uses selectors to avoid re-renders
- Implements optimistic updates with rollback

### Advanced
- Designs query key factories for cache management
- Implements prefetch-on-hover for perceived instant navigation
- Derives state with `useMemo`; never stores redundant computed state
- Configures global query client with correct staleTime, gcTime, retry policies
- Uses `immer` middleware for Zustand to handle complex nested state safely

### Expert
- Designs state architecture for complex apps: what goes where and why
- Implements real-time state sync (WebSocket → TanStack Query cache)
- Optimises render performance: measures with React DevTools Profiler, applies memo/useMemo strategically
- Builds custom Zustand middleware (logging, persistence, sync)
- Applies normalised data structures for large entity graphs

---

## AI Prompts

1. **State classification**: "I have a shopping cart (user adds items), a product catalogue (fetched from API with filters), a notification stack, and a dark mode toggle. Classify each piece of state and recommend the right tool for each."

2. **Optimistic update**: "I have a mutation that captures a payment. Write the TanStack Query `useMutation` with full optimistic update, rollback on error, and cache invalidation on settle."

3. **Re-render debugging**: "My PaymentsList component re-renders every 2 seconds even when data hasn't changed. Here is my Zustand store and component. What's causing the re-renders and how do I fix them?"

4. **URL state migration**: "I store my table filters (status, dateRange, search, page) in a Zustand store. The URL doesn't reflect the filter state. Migrate this to URL state so filters are bookmarkable."

5. **Query client design**: "Design a TanStack Query client configuration for a payments dashboard. The dashboard has: a real-time transaction feed, a slow analytics query (5s), a fast payment detail lookup, and user preferences. What staleTime and gcTime should each query have?"

---

## References

- TanStack Query documentation — tanstack.com/query — the definitive server state reference
- Zustand documentation — github.com/pmndrs/zustand
- Tanner Linsley — *Server State vs Client State* (TkDodo's blog)
- TkDodo's blog — tkdodo.eu/blog — practical React Query patterns (highly recommended)
- React documentation — *Choosing the State Structure*, *Managing State*
- Daishi Kato — *Micro State Management with React Hooks* (O'Reilly, 2022)
- React Hook Form — react-hook-form.com — form state management
