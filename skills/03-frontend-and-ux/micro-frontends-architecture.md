---
name: Micro-Frontends Architecture
slug: micro-frontends-architecture
category: 03-frontend-and-ux
proficiency: advanced
description: >
  Design and operate micro-frontend systems: Module Federation (Webpack 5 /
  Rspack), runtime composition, independent deployment pipelines, shared
  design system contracts, cross-MFE communication patterns, server-side
  composition with edge workers, and the organisational team topology that
  makes micro-frontends viable. Covers shell/host architecture, version
  negotiation, shared dependency deduplication, and testing strategies
  for independently-deployed frontend slices.
tags:
  - micro-frontends
  - module-federation
  - webpack5
  - rspack
  - runtime-composition
  - independent-deployment
  - design-system
  - team-topologies
  - next-js
  - edge-workers
status: published
---

## Principles

### 1. Vertical Ownership Over Horizontal Layers
The motivation for micro-frontends mirrors micro-services: give a full-stack
team end-to-end ownership of a **vertical business capability** (checkout,
search, account) rather than a horizontal layer (all buttons, all API calls).
Each team owns its UI slice, its API, and its data. If the team can deploy
the backend without coordinating other teams, it must also be able to deploy
the frontend independently.

### 2. Runtime Integration Is Safer Than Build-Time Integration
Build-time integration (npm packages per MFE) creates version lock-step:
every update requires all consumers to rebuild and redeploy together — the
same monolith, just slower. **Module Federation** and **ESI/edge composition**
integrate at *runtime*, allowing teams to deploy independently without
requiring consumers to rebuild.

### 3. The Shell Is Infrastructure, Not a Feature
The shell (host application) owns routing, authentication context, and the
global layout frame. It must not contain business logic. Its release cadence
is the *slowest* component — treat it as infrastructure. The thinner the
shell, the less coordination it forces.

### 4. Shared Dependencies Must Be Negotiated, Not Assumed
Two remote MFEs loading React 18.2 and React 18.3 into the same page will
break. Module Federation's `shared` configuration with `singleton: true` and
`requiredVersion` allows the host to broker a single shared instance.
**Design the shared dependency manifest as a first-class contract** between
teams, versioned alongside the shell.

### 5. Cross-MFE Communication Must Cross a Boundary, Not a Module
Direct import chains between MFEs recreate coupling. Use:
- **Custom Events** (`window.dispatchEvent`) for decoupled UI notifications
- **Shared state bus** (tiny pub/sub or Redux-style store in the shell) for
  coordinated state (auth token, cart count)
- **URL / query params** for navigation-driven state sharing

Never import a component from one MFE directly into another MFE's bundle.

---

## Implementation Patterns

### Pattern A: Module Federation Host + Remote
The host (shell) declares remote MFEs in `ModuleFederationPlugin`. At runtime,
the host fetches the remote's manifest, resolves shared dependencies, and
mounts the remote's components into the page without a full reload.

### Pattern B: Server-Side Composition with Edge Workers
For SEO-sensitive applications, assemble MFE HTML fragments at the edge
(Cloudflare Workers, AWS Lambda@Edge, or an nginx SSI layer) before sending
to the browser. Each MFE exposes an SSR endpoint; the edge stitches fragments.
This avoids client-side waterfall loading while retaining independent
deployment per MFE.

### Pattern C: Design System as a Versioned Contract
The design system is a shared npm package (`@company/ui`) consumed by all
MFEs. It must follow strict semver. MFEs pin to a minor range (`^2.3.0`).
The shell may enforce a minimum version via Module Federation's
`requiredVersion`. The design system team publishes a changelog and
deprecation policy — it is a *product* with internal consumers.

### Pattern D: Independent CI/CD per MFE
Each MFE has its own pipeline: lint → unit tests → contract tests (verifying
the exposed API shape hasn't changed) → build → publish remote entry to a
CDN path versioned by git SHA. The shell's `remoteEntry` URL uses an
environment variable pointing to the latest stable SHA, updated via GitOps.

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| Shared global CSS without scoping | One MFE's styles break another's layout | CSS Modules, Shadow DOM, or CSS-in-JS with scoped class names per MFE |
| MFEs importing directly from each other | Build-time coupling; circular dependency risk; defeats independent deploy | Communicate via custom events, URL, or shell-owned shared store only |
| Shell growing business features | Shell becomes a bottleneck; every team waits for shell releases | Shell owns only routing, auth context, layout frame — zero business logic |
| Single shared `node_modules` across all MFEs | Version conflicts; any upgrade requires all teams to coordinate | Each MFE manages its own dependencies; Module Federation brokers shared singletons |
| No contract tests between shell and remotes | Remote's API shape changes break the shell silently in production | Schema/contract tests (TypeScript types published to a registry) verify the exposed interface |
| Synchronous loading of all MFEs on initial render | Slow LCP; unused MFEs still downloaded | Lazy-load remotes on route activation; use `React.lazy` + `Suspense` for async import |
| Centralised e2e tests that span all MFEs | Tests are owned by no one; flaky; block all teams | Each MFE owns e2e for its own vertical; integration smoke test suite in the shell repo |

---

## Code Templates

### Template 1 — Webpack 5 Module Federation: Shell Configuration
```javascript
// shell/webpack.config.js
const { ModuleFederationPlugin } = require('webpack').container;
const HtmlWebpackPlugin = require('html-webpack-plugin');
const deps = require('./package.json').dependencies;

module.exports = {
  entry: './src/index.tsx',
  output: {
    publicPath: 'auto',    // required for Module Federation dynamic imports
  },
  plugins: [
    new ModuleFederationPlugin({
      name: 'shell',
      remotes: {
        // URLs resolved at runtime — injected by CI/CD per environment
        checkout: `checkout@${process.env.CHECKOUT_MFE_URL}/remoteEntry.js`,
        catalog:  `catalog@${process.env.CATALOG_MFE_URL}/remoteEntry.js`,
        account:  `account@${process.env.ACCOUNT_MFE_URL}/remoteEntry.js`,
      },
      shared: {
        react: {
          singleton: true,
          requiredVersion: deps.react,
          eager: true,     // shell bootstraps React; remotes defer to shell's copy
        },
        'react-dom': { singleton: true, requiredVersion: deps['react-dom'], eager: true },
        'react-router-dom': { singleton: true, requiredVersion: deps['react-router-dom'] },
        '@company/ui': {
          singleton: true,
          requiredVersion: '^2.0.0',   // minimum version accepted from any remote
        },
      },
    }),
    new HtmlWebpackPlugin({ template: './public/index.html' }),
  ],
};
```

### Template 2 — Webpack 5 Module Federation: Remote (Checkout MFE)
```javascript
// checkout/webpack.config.js
const { ModuleFederationPlugin } = require('webpack').container;
const deps = require('./package.json').dependencies;

module.exports = {
  entry: './src/bootstrap.tsx',  // async bootstrap avoids eager shared module issues
  output: {
    publicPath: 'auto',
    filename: 'remoteEntry.js',
  },
  plugins: [
    new ModuleFederationPlugin({
      name: 'checkout',
      filename: 'remoteEntry.js',
      exposes: {
        './CheckoutPage':  './src/pages/CheckoutPage',
        './CartWidget':    './src/components/CartWidget',
        './useCartCount':  './src/hooks/useCartCount',
      },
      shared: {
        react:          { singleton: true, requiredVersion: deps.react },
        'react-dom':    { singleton: true, requiredVersion: deps['react-dom'] },
        '@company/ui':  { singleton: true, requiredVersion: deps['@company/ui'] },
      },
    }),
  ],
};
```

```typescript
// checkout/src/bootstrap.tsx — async bootstrap prevents shared module race
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';

const root = ReactDOM.createRoot(document.getElementById('root')!);
root.render(<App />);
```

### Template 3 — Shell: Lazy-Load Remote MFE with Error Boundary
```typescript
// shell/src/RemoteLoader.tsx
import React, { Suspense, ComponentType, lazy } from 'react';

interface RemoteLoaderProps {
  remote: string;        // e.g. 'checkout'
  module: string;        // e.g. './CheckoutPage'
  fallback?: React.ReactNode;
  errorFallback?: React.ReactNode;
}

class MFEErrorBoundary extends React.Component<
  { fallback: React.ReactNode; children: React.ReactNode },
  { hasError: boolean }
> {
  state = { hasError: false };
  static getDerivedStateFromError = () => ({ hasError: true });
  render() {
    return this.state.hasError ? this.props.fallback : this.props.children;
  }
}

function loadRemote(remote: string, module: string): Promise<{ default: ComponentType<any> }> {
  // Module Federation dynamic import
  return import(/* webpackIgnore: true */ `${remote}/${module.replace('./', '')}`);
}

export function RemoteLoader({ remote, module, fallback, errorFallback }: RemoteLoaderProps) {
  const RemoteComponent = lazy(() => loadRemote(remote, module));

  return (
    <MFEErrorBoundary fallback={errorFallback ?? <div>Failed to load {remote}</div>}>
      <Suspense fallback={fallback ?? <div>Loading...</div>}>
        <RemoteComponent />
      </Suspense>
    </MFEErrorBoundary>
  );
}

// Usage in shell router:
// <Route path="/checkout/*" element={
//   <RemoteLoader remote="checkout" module="./CheckoutPage" />
// } />
```

### Template 4 — Cross-MFE Communication: Custom Event Bus
```typescript
// shell/src/eventBus.ts — tiny typed pub/sub using CustomEvent
// Injected into window so all MFEs share one instance without module sharing.

export type MFEEventMap = {
  'cart:updated':       { itemCount: number; total: number };
  'user:authenticated': { userId: string; roles: string[] };
  'user:signed-out':    Record<string, never>;
  'navigation:push':    { path: string; state?: unknown };
};

type MFEEventType = keyof MFEEventMap;

export const eventBus = {
  emit<T extends MFEEventType>(type: T, detail: MFEEventMap[T]): void {
    window.dispatchEvent(new CustomEvent(`mfe:${type}`, { detail, bubbles: false }));
  },

  on<T extends MFEEventType>(
    type: T,
    handler: (detail: MFEEventMap[T]) => void
  ): () => void {
    const listener = (e: Event) => handler((e as CustomEvent).detail);
    window.addEventListener(`mfe:${type}`, listener);
    return () => window.removeEventListener(`mfe:${type}`, listener);   // returns cleanup fn
  },
};

// In the checkout MFE after adding to cart:
// eventBus.emit('cart:updated', { itemCount: 3, total: 149.99 });

// In the shell header to update the cart badge:
// useEffect(() => eventBus.on('cart:updated', ({ itemCount }) => setCartCount(itemCount)), []);
```

### Template 5 — Server-Side Composition: Edge Worker Fragment Stitcher
```typescript
// edge-worker/src/index.ts — Cloudflare Worker assembling MFE HTML fragments
export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // Route → MFE fragment origin map (from environment bindings)
    const fragmentOrigins: Record<string, string> = {
      '/checkout': 'https://checkout-mfe.internal',
      '/catalog':  'https://catalog-mfe.internal',
      '/account':  'https://account-mfe.internal',
    };

    const matchedPrefix = Object.keys(fragmentOrigins)
      .find(prefix => url.pathname.startsWith(prefix));

    if (!matchedPrefix) {
      // Serve shell HTML for unmatched routes (SPA fallback)
      return fetch(`https://shell.internal${url.pathname}${url.search}`);
    }

    // Fetch shell template and MFE fragment in parallel
    const [shellRes, fragmentRes] = await Promise.all([
      fetch('https://shell.internal/template.html'),
      fetch(`${fragmentOrigins[matchedPrefix]}${url.pathname}${url.search}`, {
        headers: {
          'x-forwarded-for': request.headers.get('cf-connecting-ip') ?? '',
          'accept': 'text/html-fragment',
          'cookie': request.headers.get('cookie') ?? '',
        },
      }),
    ]);

    const [shellHtml, fragmentHtml] = await Promise.all([
      shellRes.text(),
      fragmentRes.text(),
    ]);

    // Inject fragment into shell's content slot
    const composed = shellHtml.replace(
      '<!-- MFE_CONTENT_SLOT -->',
      fragmentHtml
    );

    return new Response(composed, {
      headers: {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'private, no-store',
      },
    });
  },
};
```

### Template 6 — Contract Test: Verifying Remote Module Shape
```typescript
// checkout/src/__tests__/remote-contract.test.ts
// Runs in the checkout MFE's CI pipeline to verify it still satisfies
// the contract the shell expects. Fails fast before deployment.

import { describe, it, expect } from 'vitest';

describe('Module Federation contract', () => {
  it('exposes CheckoutPage as a default React component', async () => {
    // Dynamic import simulates what Module Federation does at runtime
    const mod = await import('../pages/CheckoutPage');
    expect(typeof mod.default).toBe('function');
    // Verify it has the expected display name (shell uses it for a11y)
    expect(mod.default.displayName ?? mod.default.name).toBe('CheckoutPage');
  });

  it('exposes CartWidget with required props interface', async () => {
    const mod = await import('../components/CartWidget');
    expect(typeof mod.default).toBe('function');
    // A TypeScript compilation error here means the contract type was broken.
    // This test is a runtime double-check.
  });

  it('exposes useCartCount hook returning a number', async () => {
    const { renderHook } = await import('@testing-library/react');
    const { useCartCount } = await import('../hooks/useCartCount');
    const { result } = renderHook(() => useCartCount());
    expect(typeof result.current).toBe('number');
  });

  it('does not re-export React as a named export (shared singleton guard)', async () => {
    // If a remote accidentally bundles and re-exports React it breaks the singleton
    const mod = await import('../pages/CheckoutPage') as Record<string, unknown>;
    expect(mod['React']).toBeUndefined();
    expect(mod['createElement']).toBeUndefined();
  });
});
```

---

## Decision Matrix

| Decision | Option A | Option B | Guidance |
|---|---|---|---|
| **Integration mechanism** | Module Federation (runtime JS) | npm package per MFE (build-time) | Module Federation for true independent deployment; npm packages only for shared libraries (design system) |
| **Rendering strategy** | CSR (client-side, Module Federation) | SSR / Edge composition | CSR simpler to operate; SSR/edge for SEO-critical, auth-gated pages |
| **Cross-MFE communication** | Custom Events on `window` | Shared Redux store (Module Federation shared) | Custom events for loose coupling; shared store only if shell owns the state slice |
| **Shell routing** | React Router in shell, lazy remote loads | Each MFE owns its own router | Shell owns top-level routes; MFEs own sub-routes with `<Route path="/*">` |
| **Shared dependency strategy** | `singleton: true` in Module Federation shared config | Bundle per MFE (no sharing) | Singleton for React, react-dom, design system; bundle separately for MFE-specific libs |
| **Team structure** | Vertical slice teams (recommended) | Shared frontend platform team owning shell + all MFEs | Vertical teams are the whole point; platform team owns only the shell as infra |
| **Testing ownership** | Each MFE owns unit + e2e for its vertical | Central QA team owns all e2e | Distributed ownership scales; central QA becomes a bottleneck |
| **When NOT to use MFE** | Large product with 3+ independent teams | Single team, single product | MFE coordination overhead requires multiple teams to be worth it; don't adopt for a single-team app |

---

## Proficiency Levels

### Novice
- Understands the motivation (team autonomy, independent deployment) vs the cost (operational complexity)
- Knows what Module Federation is; can read a `ModuleFederationPlugin` config
- Distinguishes a micro-frontend from a component library or a monorepo

### Intermediate
- Configures Module Federation host + remote with shared dependency negotiation
- Implements lazy-loaded remote mounting with `React.lazy` + error boundaries
- Sets up independent CI/CD pipelines per MFE publishing to a versioned CDN path
- Implements typed custom event bus for cross-MFE communication
- Writes contract tests verifying exposed module shape before deployment

### Advanced
- Designs the shell/remote split aligned with Team Topologies vertical ownership
- Implements server-side or edge composition for SSR micro-frontends
- Manages shared design system versioning with semver and `requiredVersion` contracts
- Diagnoses and resolves Module Federation `singleton` violations (duplicate React instances)
- Architects a version negotiation strategy that allows gradual upgrade without lock-step

### Expert
- Evaluates and adopts next-generation MFE runtimes (Rspack Module Federation 2.0, native federation)
- Designs enterprise-scale MFE platform supporting 10+ teams with automated version dashboards
- Implements edge-side rendering with fragment streaming (HTTP/2 server push, Suspense streaming SSR)
- Defines cross-team governance: MFE registry, contract schema, deprecation policy, performance budgets
- Measures and enforces per-MFE performance budgets in CI (Lighthouse CI, bundle size gates)

---

## AI Prompts

```
You are a micro-frontend architect. I have a monolithic React SPA with 6
feature areas owned by 3 teams. Describe the step-by-step migration plan to
Module Federation: how to identify vertical slice boundaries, what to extract
first, how to run the monolith and the first MFE in parallel (strangler fig),
and how to avoid breaking users during the transition.
```

```
Acting as a performance engineer: my shell app loads 3 Module Federation
remotes eagerly on initial page load, causing LCP of 4.2 seconds. Describe
the lazy-loading strategy: which Webpack config changes, how to use
React.lazy with Suspense for route-based MFE loading, and how to preload
MFEs on hover/focus to reduce perceived latency.
```

```
Explain the Module Federation shared dependency pitfall where two MFEs end
up with two separate React instances in the same browser tab. What symptoms
does this cause? Walk me through the exact webpack.config.js changes to fix
it using singleton: true and requiredVersion, and how to verify it's fixed
using React DevTools.
```

```
I need to implement SSR for a micro-frontend application where each team
owns a Next.js app. Compare three approaches: (1) edge composition with
Cloudflare Workers, (2) nginx server-side includes (SSI), (3) Module
Federation with Next.js. For each, describe the deployment model, caching
strategy, and the main failure mode.
```

```
Design a cross-MFE state management strategy for a checkout flow that spans
three MFEs: catalog (adds to cart), cart (manages items), and checkout
(payment). The shell hosts all three. What state lives where, how do MFEs
communicate state changes without importing each other, and how do you
handle a user navigating away mid-checkout?
```

---

## References

- **Mezzalira, Luca** — *Building Micro-Frontends* (O'Reilly, 2021)
- **Module Federation docs** — https://webpack.js.org/concepts/module-federation/
- **Module Federation 2.0 (Rspack)** — https://module-federation.io
- **micro-frontends.org** — Cam Jackson's original reference article
- **Native Federation** — https://github.com/angular-architects/native-federation (standards-based alternative)
- **Zalando Mosaic** — tailor + fragment composition reference architecture
- **OpenComponents** — https://opencomponents.github.io — server-side MFE registry
- **Team Topologies** — Skelton & Pais; vertical stream-aligned team model
- **Lighthouse CI** — https://github.com/GoogleChrome/lighthouse-ci — per-MFE performance budgets
- **Module Federation examples** — https://github.com/module-federation/module-federation-examples
- **SysSkills cross-reference** — `frontend-architecture-ux-patterns`, `cicd-gitops-strategy`,
  `platform-engineering-idp`
