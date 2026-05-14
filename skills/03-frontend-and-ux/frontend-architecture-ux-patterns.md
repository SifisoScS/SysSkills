---
name: "Frontend Architecture & Modern UX Patterns"
slug: frontend-architecture-ux-patterns
category: "03-frontend-and-ux"
proficiency: Architect
description: "Master modern frontend architecture patterns, component design, rendering strategies, state management, and UX principles to build responsive, accessible, performant, and maintainable user interfaces. Covers Server Components, micro-frontends, design systems, Core Web Vitals, and domain-driven UI aligned to backend Bounded Contexts."
tags: [frontend, architecture, react, nextjs, server-components, micro-frontends, design-system, state-management, core-web-vitals, accessibility, ssr, csr, feature-sliced-design, zustand, tanstack-query, atomic-design]
status: published
---

# Frontend Architecture & Modern UX Patterns

## Principles

**Component-Driven Development**
UIs are composed of small, focused, independently testable components. Each component has a single responsibility. Complexity emerges from composition, not from individual component size. A component that does too much — renders a form, fetches data, manages modal state, and formats currency — cannot be reused, tested, or understood in isolation.

**Separation of Concerns: UI, Logic, and State**
What renders is separate from what it knows and what it fetches. A component that mixes rendering logic, data fetching, and global state mutations is brittle and untestable. Separate: presentational components (pure render), container or hook-based logic (business rules, transformations), and data layer (fetching, caching, mutations).

**Performance Is a Design Decision, Not an Afterthought**
Core Web Vitals (LCP, INP, CLS) are measurable, user-perceived performance signals that affect both user retention and search ranking. Performance decisions — rendering strategy, code splitting, image optimisation, font loading — must be made at design time, not retrofitted after a lighthouse audit fails.

**Accessibility and Internationalisation Are Not Optional**
WCAG 2.2 AA is the minimum bar. Screen reader support, keyboard navigation, colour contrast, and focus management must be designed in, not bolted on. Internationalisation (i18n) retrofitted into a mature codebase costs 10x more than designing for it from the first component. Use design tokens and message catalogues from day one.

**Design Systems Are the Single Source of Truth**
A design system is not a component library. It is the shared vocabulary of colour tokens, spacing scales, typography, interaction patterns, and component contracts between design and engineering. Without one, every team builds their own buttons and every product looks different. With one, consistency is the default and customisation is intentional.

**Align UI to Backend Bounded Contexts**
Frontend modules should mirror backend Bounded Contexts where possible. The Orders feature owns everything from the order list UI to the order API calls to the order state slice. This alignment enables full-stack feature teams, reduces cross-team coordination, and makes the codebase navigable by business capability rather than technical layer.

---

## Implementation Patterns

### Pattern 1 — Rendering Strategy Selection

**Client-Side Rendering (CSR)**
The server sends an empty HTML shell; JavaScript renders the UI in the browser. Good for highly interactive dashboards and internal tools where SEO is irrelevant. Poor initial load (blank page until JS parses and executes); bad for content-heavy or public-facing pages.

**Server-Side Rendering (SSR)**
The server renders the full HTML for each request. Good for dynamic, personalised, SEO-critical pages. Higher server load; slower time-to-first-byte under load compared to static.

**Static Site Generation (SSG)**
Pages rendered at build time. Fastest possible delivery (CDN-cacheable). Only appropriate for content that does not change per-request (marketing pages, documentation, blog posts).

**React Server Components (RSC) + Streaming (Next.js App Router)**
The recommended hybrid for 2026. Server Components render on the server (zero JavaScript sent to client, direct database/API access, no serialisation overhead). Client Components handle interactivity. Streaming (`Suspense`) sends HTML progressively — the shell arrives immediately, data-dependent sections stream in as they resolve.

```
Route /orders/[id]:
  └── OrderLayout (Server Component — fetches order, renders shell)
      ├── OrderHeader (Server Component — static metadata)
      ├── Suspense fallback=<OrderLinesSkeleton>
      │     └── OrderLines (Server Component — streams when ready)
      └── OrderActions (Client Component — needs onClick, useState)
```

**Partial Prerendering (PPR — Next.js 15+)**
Static shell prerendered at build time; dynamic holes streamed at request time. Best of SSG (CDN cache) and SSR (fresh dynamic data) in one page.

### Pattern 2 — Feature-Sliced Design (Project Structure)

Organise by business feature, not by technical type. Aligns directly with DDD Bounded Contexts on the frontend:

```
src/
├── app/                   ← routing and layout (Next.js app dir or React Router)
├── features/              ← one folder per business capability
│   ├── orders/
│   │   ├── api/           ← TanStack Query hooks (useOrders, usePlaceOrder)
│   │   ├── components/    ← OrderList, OrderCard, OrderStatusBadge
│   │   ├── hooks/         ← useOrderFilters, useOrderPagination
│   │   ├── stores/        ← Zustand slice (if client state needed)
│   │   ├── types.ts       ← OrderSummary, PlaceOrderRequest DTOs
│   │   └── index.ts       ← public API of this feature
│   ├── payments/
│   └── customers/
├── shared/                ← design system, utilities, shared hooks
│   ├── ui/                ← Button, Input, Modal, Badge (shadcn/ui wrappers)
│   ├── design-tokens/     ← colours, spacing, typography (CSS variables)
│   └── lib/               ← formatters, validators, HTTP client
└── pages/ (or app/)       ← thin route entry points; compose features
```

The `index.ts` barrel is the only public surface of a feature. Other features import from `features/orders`, never from `features/orders/components/OrderCard`.

### Pattern 3 — State Management Strategy

Not all state is equal. Choose the right bucket:

| State Type | Owner | Tool |
|---|---|---|
| Server state (async, remote) | TanStack Query | Caching, background refetch, optimistic updates |
| Global UI state (modals, themes, user prefs) | Zustand / Jotai atom | Lightweight, no boilerplate |
| Form state | React Hook Form + Zod | Validation, submission, field-level errors |
| Local UI state (open/closed, hover, focus) | `useState` / `useReducer` | Collocated, no library needed |
| URL state (filters, pagination, tabs) | Search params (`useSearchParams`) | Shareable, bookmarkable, back-button safe |

The most common mistake is putting server state in a global store (Redux/Zustand) and manually invalidating it. TanStack Query owns the server state cache; the component just declares what it needs.

### Pattern 4 — Micro-Frontends (Module Federation)

When multiple teams must deploy frontend features independently at scale:

```
Shell App (host)
  ├── loads Header MFE   (team-platform)
  ├── loads Orders MFE   (team-ordering)   ← independent deploy
  ├── loads Payments MFE (team-payments)   ← independent deploy
  └── loads Analytics MFE (team-data)
```

**Module Federation (Webpack 5 / Rspack)**: each MFE exposes components/routes as remote modules. The shell loads them at runtime. No monorepo required; each MFE has its own CI/CD pipeline.

**When to use**: > 3 teams, > 1M LOC frontend, independent release cadences per team. Micro-frontends add significant operational complexity — shared dependency versioning, cross-MFE communication, end-to-end testing. Use only when team autonomy genuinely requires it.

**Prefer Modular Monorepo first**: a Turborepo/Nx monorepo with feature packages gives most of the benefits (code sharing, independent builds) with far less runtime complexity.

### Pattern 5 — Design System Architecture

```
design-tokens/          ← primitive values: colour-blue-500, spacing-4, font-size-lg
  └── tokens.css        ← CSS custom properties (--color-primary, --spacing-md)

ui-components/          ← accessible, unstyled or lightly styled primitives
  ├── Button/           ← uses design tokens; no business logic
  ├── Input/
  ├── Modal/
  └── index.ts          ← public API

feature-components/     ← composed from ui-components + business logic
  └── OrderStatusBadge/ ← uses Button + design tokens + order domain types
```

Design tokens decouple visual decisions from component implementation. Changing the brand primary colour is a one-line token change — not a find-and-replace across 200 components.

**Storybook** as the living contract: every component has stories covering all states (default, hover, disabled, error, loading, empty). Stories are the acceptance criteria between design and engineering, and the regression baseline for visual testing.

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| God component | One component fetches data, manages modals, formats currency, and renders a table; untestable and unreusable | Decompose by responsibility: fetch in a hook, format in a utility, render in a presentational component |
| Prop drilling | State passed through 5 component layers to reach the one that needs it | Collocate state at the lowest common ancestor; use context or Zustand for genuinely shared state |
| Server state in global store | Redux manually caches API responses; stale data, cache invalidation bugs, boilerplate everywhere | TanStack Query owns server state; global store owns UI state only |
| No code splitting | Entire application bundle downloaded on first load; slow LCP on entry page | Dynamic `import()` per route; `React.lazy` for heavy components; Next.js automatic route splitting |
| Ignoring bundle size | Third-party libraries added without checking size; 500KB gzipped for a dashboard nobody benchmarked | Use `bundlesize`, `webpack-bundle-analyzer`, or `next/bundle-analyzer`; set size budgets in CI |
| Building without a design system | Every team invents their own Button; inconsistent spacing, colours, and interaction patterns across the product | Invest in a minimal design system early; shadcn/ui provides accessible unstyled components to build on |
| Accessibility as a final step | Screen reader support, keyboard navigation, and colour contrast retrofitted after launch; expensive and incomplete | Use `eslint-plugin-jsx-a11y`; test with keyboard and screen reader from the first component; automate in CI |

---

## Code Templates

### Next.js — Server Component with Streaming (App Router)

```tsx
// app/orders/[id]/page.tsx
import { Suspense } from 'react';
import { OrderHeader }       from '@/features/orders/components/OrderHeader';
import { OrderLines }        from '@/features/orders/components/OrderLines';
import { OrderLinesSkeleton} from '@/features/orders/components/OrderLinesSkeleton';
import { getOrder }          from '@/features/orders/api/server';

// Server Component — runs on the server, zero JS sent to client
export default async function OrderPage({ params }: { params: { id: string } }) {
    const order = await getOrder(params.id);   // direct DB/API call, no fetch needed

    return (
        <main>
            <OrderHeader order={order} />
            {/* Stream OrderLines independently — shell renders immediately */}
            <Suspense fallback={<OrderLinesSkeleton />}>
                <OrderLines orderId={params.id} />
            </Suspense>
        </main>
    );
}
```

### TanStack Query — Data Fetching Hook with Optimistic Update

```tsx
// features/orders/api/useOrders.ts
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { ordersApi } from './ordersApi';
import type { Order, PlaceOrderRequest } from '../types';

const ORDERS_KEY = (customerId: string) => ['orders', customerId] as const;

export function useCustomerOrders(customerId: string) {
    return useQuery({
        queryKey: ORDERS_KEY(customerId),
        queryFn:  () => ordersApi.getByCustomer(customerId),
        staleTime: 30_000,   // 30s — don't refetch if data is fresh
    });
}

export function usePlaceOrder() {
    const queryClient = useQueryClient();

    return useMutation({
        mutationFn: (req: PlaceOrderRequest) => ordersApi.place(req),
        onMutate: async (req) => {
            // Optimistic update — add pending order immediately
            await queryClient.cancelQueries({ queryKey: ['orders'] });
            const previous = queryClient.getQueryData(ORDERS_KEY(req.customerId));
            queryClient.setQueryData(ORDERS_KEY(req.customerId), (old: Order[]) => [
                ...old,
                { ...req, id: 'temp', status: 'pending' },
            ]);
            return { previous };
        },
        onError: (_err, req, ctx) => {
            queryClient.setQueryData(ORDERS_KEY(req.customerId), ctx?.previous);
        },
        onSettled: (_data, _err, req) => {
            queryClient.invalidateQueries({ queryKey: ORDERS_KEY(req.customerId) });
        },
    });
}
```

### Zustand — Global UI State (Sidebar + Theme)

```ts
// shared/stores/uiStore.ts
import { create } from 'zustand';
import { persist } from 'zustand/middleware';

interface UiState {
    sidebarOpen: boolean;
    theme: 'light' | 'dark' | 'system';
    toggleSidebar: () => void;
    setTheme: (theme: UiState['theme']) => void;
}

export const useUiStore = create<UiState>()(
    persist(
        (set) => ({
            sidebarOpen: true,
            theme: 'system',
            toggleSidebar: () => set((s) => ({ sidebarOpen: !s.sidebarOpen })),
            setTheme: (theme) => set({ theme }),
        }),
        { name: 'ui-preferences' }   // persisted to localStorage
    )
);
```

### TypeScript — Zod Schema + React Hook Form

```tsx
// features/orders/components/PlaceOrderForm.tsx
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { usePlaceOrder } from '../api/useOrders';

const placeOrderSchema = z.object({
    productId: z.string().uuid('Invalid product'),
    quantity:  z.number().int().min(1, 'At least 1').max(100, 'Max 100'),
});
type PlaceOrderForm = z.infer<typeof placeOrderSchema>;

export function PlaceOrderForm({ customerId }: { customerId: string }) {
    const { mutate, isPending, isError } = usePlaceOrder();
    const { register, handleSubmit, formState: { errors } } = useForm<PlaceOrderForm>({
        resolver: zodResolver(placeOrderSchema),
    });

    return (
        <form onSubmit={handleSubmit((data) => mutate({ ...data, customerId }))}
              aria-label="Place order">
            <label htmlFor="productId">Product</label>
            <input id="productId" {...register('productId')}
                   aria-describedby="productId-error" />
            {errors.productId && (
                <span id="productId-error" role="alert">{errors.productId.message}</span>
            )}

            <label htmlFor="quantity">Quantity</label>
            <input id="quantity" type="number" {...register('quantity', { valueAsNumber: true })}
                   aria-describedby="quantity-error" />
            {errors.quantity && (
                <span id="quantity-error" role="alert">{errors.quantity.message}</span>
            )}

            {isError && <p role="alert">Failed to place order. Please try again.</p>}

            <button type="submit" disabled={isPending} aria-busy={isPending}>
                {isPending ? 'Placing…' : 'Place Order'}
            </button>
        </form>
    );
}
```

### CSS — Design Token System

```css
/* shared/design-tokens/tokens.css */
:root {
    /* Colour primitives */
    --color-blue-500:  #3b82f6;
    --color-blue-600:  #2563eb;
    --color-red-500:   #ef4444;
    --color-green-500: #22c55e;
    --color-gray-50:   #f9fafb;
    --color-gray-900:  #111827;

    /* Semantic tokens — decouple intent from value */
    --color-primary:         var(--color-blue-500);
    --color-primary-hover:   var(--color-blue-600);
    --color-danger:          var(--color-red-500);
    --color-success:         var(--color-green-500);
    --color-surface:         var(--color-gray-50);
    --color-text:            var(--color-gray-900);

    /* Spacing scale (4px base) */
    --spacing-1:  0.25rem;   /*  4px */
    --spacing-2:  0.5rem;    /*  8px */
    --spacing-4:  1rem;      /* 16px */
    --spacing-6:  1.5rem;    /* 24px */
    --spacing-8:  2rem;      /* 32px */

    /* Typography */
    --font-size-sm:   0.875rem;
    --font-size-base: 1rem;
    --font-size-lg:   1.125rem;
    --font-size-xl:   1.25rem;
    --font-weight-medium: 500;
    --font-weight-bold:   700;

    /* Border radius */
    --radius-sm: 0.25rem;
    --radius-md: 0.5rem;
    --radius-lg: 0.75rem;
}

[data-theme="dark"] {
    --color-surface: #1f2937;
    --color-text:    #f9fafb;
}
```

---

## Decision Matrix

| Requirement | Rendering Strategy | Framework | State |
|---|---|---|---|
| Public-facing, SEO-critical | SSR + ISR / PPR | Next.js 15 App Router | TanStack Query |
| Internal dashboard / admin tool | CSR or light SSR | Next.js or Vite + React | TanStack Query + Zustand |
| Content marketing site | SSG + CDN | Next.js or Astro | None (static) |
| Highly interactive SPA (real-time) | CSR + WebSocket | Vite + React or SolidJS | Zustand + TanStack Query |
| Multi-team, independent deploys | Micro-frontends (Module Federation) | Turborepo first; MFE only if team autonomy requires | Per-MFE isolated stores |
| Mobile-first / offline | PWA + Service Worker | Next.js PWA or React Native Web | TanStack Query with offline persistence |
| Design system only | N/A | Storybook + shadcn/ui base | N/A |

---

## Proficiency Levels

### Awareness
- Can explain the difference between CSR, SSR, SSG, and React Server Components.
- Understands what a design system is and why design tokens exist.
- Knows what Core Web Vitals measure (LCP, INP, CLS) and why they matter.

### Applied
- Builds feature-sliced Next.js applications with Server and Client Components.
- Uses TanStack Query for server state and Zustand for UI state; does not conflate the two.
- Implements accessible forms with React Hook Form + Zod validation.
- Applies design tokens via CSS custom properties; builds components that respect theme switching.

### Master
- Designs complex frontend architectures with domain-aligned feature modules.
- Implements optimistic updates, background sync, and cache invalidation with TanStack Query.
- Optimises for Core Web Vitals: code splitting, image optimisation, font loading strategy, Suspense boundaries.
- Integrates OpenTelemetry Web SDK and Real User Monitoring (RUM) for frontend observability.

### Architect
- Defines organisation-wide frontend platform: framework standards, design system governance, performance budgets, accessibility compliance programme, Storybook component library strategy.
- Evaluates micro-frontend adoption: identifies when team autonomy and deployment independence genuinely justify the operational complexity.
- Aligns frontend module boundaries with backend Bounded Contexts; designs BFF (Backend for Frontend) APIs in partnership with backend teams.
- Makes rendering strategy decisions at the page/route level based on SEO, personalisation, and performance requirements.

---

## AI Prompts

**Design a frontend architecture:**
> Design the frontend architecture for this application: [describe product, user types, key features, team size]. Specify: project structure (feature-sliced), rendering strategy per route type, state management approach, design system foundation, and how frontend modules align to backend Bounded Contexts.

**Review a component for quality:**
> Review this React component for architecture issues. Check: Does it mix concerns (data fetching, business logic, rendering)? Is server state in a global store instead of TanStack Query? Is there prop drilling? Are there accessibility issues (missing labels, non-semantic HTML, focus management)? [paste component]

**Optimise for Core Web Vitals:**
> My Next.js page has an LCP of 4.2s and a CLS of 0.18. Here is the page structure: [describe or paste code]. Identify the top 3 causes and provide specific code changes to fix them.

**Design a design system:**
> Design the token structure and component hierarchy for a design system for [describe product and brand]. Include: colour token naming convention (primitives vs semantic), spacing scale, typography scale, and which components should be in the shared `ui` layer vs the feature layer.

**Choose a rendering strategy:**
> For these routes in our application: [list routes with description of data freshness, personalisation, and SEO requirements], recommend the rendering strategy for each (SSG, SSR, CSR, RSC + Suspense, PPR) and justify each choice.

---

## References

**Books**
- Micah Godbolt — *Frontend Architecture for Design Systems* (O'Reilly, 2016)
- Luca Mezzalira — *Building Micro-Frontends* (O'Reilly, 2021)

**Documentation & Guides**
- [Next.js App Router Documentation](https://nextjs.org/docs/app) — Server Components, Streaming, PPR
- [TanStack Query Documentation](https://tanstack.com/query) — server state management
- [web.dev Core Web Vitals](https://web.dev/vitals/) — LCP, INP, CLS measurement and optimisation
- [WCAG 2.2 Quick Reference](https://www.w3.org/WAI/WCAG22/quickref/) — accessibility compliance

**Tooling**
- [shadcn/ui](https://ui.shadcn.com/) — accessible, unstyled component primitives built on Radix UI
- [Storybook](https://storybook.js.org/) — component development, documentation, and visual regression
- [Zustand](https://zustand-demo.pmnd.rs/) — lightweight global UI state
- [React Hook Form](https://react-hook-form.com/) + [Zod](https://zod.dev/) — form validation

**Related Skills**
- `04-backend-and-services/api-design-strategy` — BFF pattern; the frontend team owns the BFF that aggregates backend services
- `02-architecture-and-design/ddd-fundamentals` — frontend feature modules align to backend Bounded Contexts; Ubiquitous Language applies to UI labels and API field names
- `08-quality-testing-observability/observability-telemetry-strategy` — OpenTelemetry Web SDK for frontend traces; Real User Monitoring (RUM) for Core Web Vitals in production
- `06-security-and-compliance/authentication-and-authorization` — auth UI patterns (Passkey registration, OAuth2 PKCE flow in SPA, secure token storage in httpOnly cookies)
