---
name: Web Performance Optimisation
slug: web-performance-optimisation
category: 03-frontend-and-ux
proficiency: advanced
description: >
  Optimise web application performance across Core Web Vitals (LCP, INP, CLS),
  JavaScript bundle size, rendering strategies, image optimisation, caching,
  and network delivery. Covers Lighthouse CI gates, resource hints, code
  splitting, critical CSS, lazy loading, and performance budgets.
tags:
  - web-performance
  - core-web-vitals
  - lcp
  - inp
  - cls
  - bundle-optimisation
  - code-splitting
  - lazy-loading
  - lighthouse
  - performance-budget
status: published
---

## Principles

### Core Web Vitals (Google's UX Metrics)

| Metric | Measures | Good | Needs Work | Poor |
|--------|----------|------|------------|------|
| **LCP** (Largest Contentful Paint) | Loading speed — when is the main content visible? | < 2.5s | 2.5–4s | > 4s |
| **INP** (Interaction to Next Paint) | Responsiveness — how fast does the page respond to input? | < 200ms | 200–500ms | > 500ms |
| **CLS** (Cumulative Layout Shift) | Visual stability — does content jump around? | < 0.1 | 0.1–0.25 | > 0.25 |

Core Web Vitals are a Google ranking signal. They are measured at the 75th percentile of real users (field data via CrUX), not lab data.

### The Performance Waterfall
Every millisecond of page load comes from one of these stages:
```
DNS lookup → TCP handshake → TLS → Request → TTFB → Download → Parse/Render
```
Key targets:
- **TTFB** (Time to First Byte): < 600ms (server-side)
- **FCP** (First Contentful Paint): < 1.8s (first visible pixel)
- **LCP**: < 2.5s (main hero content)
- **TTI** (Time to Interactive): all event handlers attached

### The 80/20 of Performance Wins
1. Reduce JavaScript payload (bundle splitting, tree shaking)
2. Optimise the LCP element (preload, proper image sizing, fast TTFB)
3. Eliminate render-blocking resources (async/defer scripts, inline critical CSS)
4. Use a CDN with aggressive caching for static assets
5. Compress text (Brotli > gzip) and use modern image formats (WebP, AVIF)

---

## Implementation Patterns

### Pattern 1 — Vite Bundle Optimisation (React/TypeScript)
```typescript
// vite.config.ts — production bundle splitting and optimisation

import { defineConfig, splitVendorChunkPlugin } from 'vite';
import react from '@vitejs/plugin-react';
import { visualizer } from 'rollup-plugin-visualizer';
import viteCompression from 'vite-plugin-compression';

export default defineConfig(({ mode }) => ({
  plugins: [
    react(),
    splitVendorChunkPlugin(),  // vendor chunk separate from app code (long-term cache)

    // Analyse bundle sizes — open stats.html after build
    mode === 'analyze' && visualizer({
      open: true,
      gzipSize: true,
      brotliSize: true,
      filename: 'stats.html',
    }),

    // Generate .br and .gz files for nginx pre-compressed serving
    viteCompression({
      algorithm: 'brotliCompress',
      ext: '.br',
      threshold: 1024,  // compress files > 1KB
    }),
    viteCompression({
      algorithm: 'gzip',
      ext: '.gz',
      threshold: 1024,
    }),
  ],

  build: {
    rollupOptions: {
      output: {
        // Manual chunk splitting — group by domain to maximise cache reuse
        manualChunks(id) {
          if (id.includes('node_modules')) {
            // Heavy visualisation library in its own chunk
            if (id.includes('recharts') || id.includes('d3-')) return 'charts';
            // Date handling
            if (id.includes('date-fns') || id.includes('dayjs')) return 'dates';
            // Form libraries
            if (id.includes('react-hook-form') || id.includes('zod')) return 'forms';
            // All other vendor code
            return 'vendor';
          }
          // Route-level code splitting handled by React.lazy (see Pattern 2)
        },
        // Deterministic chunk names for long-term caching
        chunkFileNames: 'assets/[name]-[hash].js',
        entryFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
    // Target modern browsers to reduce polyfill overhead
    target: ['es2020', 'chrome89', 'firefox88', 'safari14'],
    // Warn when any chunk exceeds 500KB
    chunkSizeWarningLimit: 500,
    sourcemap: mode === 'production' ? 'hidden' : true,
  },

  // Optimise dev server
  optimizeDeps: {
    include: ['react', 'react-dom', 'react-router-dom'],
  },
}));
```

### Pattern 2 — Code Splitting and Lazy Loading (React)
```tsx
// src/router/routes.tsx — route-based code splitting

import React, { Suspense, lazy } from 'react';
import { Routes, Route } from 'react-router-dom';
import { PageSkeleton } from '@/components/PageSkeleton';

// Lazy-load route components — each becomes a separate chunk
// Only loaded when the user navigates to that route
const Dashboard  = lazy(() => import('@/pages/Dashboard'));
const Payments   = lazy(() => import('@/pages/Payments'));
const Analytics  = lazy(() => import('@/pages/Analytics'));
// Heavy page — import with explicit chunk name for better debugging
const Reports    = lazy(() =>
  import(/* webpackChunkName: "reports" */ '@/pages/Reports')
);

export function AppRoutes() {
  return (
    // Suspense shows a skeleton while the chunk loads
    <Suspense fallback={<PageSkeleton />}>
      <Routes>
        <Route path="/"           element={<Dashboard />} />
        <Route path="/payments/*" element={<Payments />} />
        <Route path="/analytics"  element={<Analytics />} />
        <Route path="/reports/*"  element={<Reports />} />
      </Routes>
    </Suspense>
  );
}

// ─── Component-level lazy loading ────────────────────────────────────────────

// src/pages/Dashboard.tsx — defer below-fold heavy components

import { lazy, Suspense, useEffect, useState } from 'react';

// Only load the chart library when the chart section comes into view
const RevenueChart = lazy(() => import('@/components/RevenueChart'));
const TransactionTable = lazy(() => import('@/components/TransactionTable'));

export function Dashboard() {
  const [showCharts, setShowCharts] = useState(false);

  useEffect(() => {
    // Defer chart loading until after TTI (main thread free)
    const timer = setTimeout(() => setShowCharts(true), 0);
    return () => clearTimeout(timer);
  }, []);

  return (
    <div>
      {/* Critical above-fold content — always rendered immediately */}
      <KPISummary />

      {/* Below-fold charts — lazy loaded after initial render */}
      {showCharts && (
        <Suspense fallback={<ChartSkeleton />}>
          <RevenueChart />
          <TransactionTable />
        </Suspense>
      )}
    </div>
  );
}
```

### Pattern 3 — Image Optimisation Pipeline
```tsx
// src/components/OptimisedImage.tsx
// Responsive images with lazy loading, AVIF/WebP, and LCP preloading

interface OptimisedImageProps {
  src: string;         // base path, e.g. "/images/hero"
  alt: string;
  width: number;
  height: number;
  priority?: boolean;  // true for LCP element — disables lazy load, adds preload
  sizes?: string;      // CSS sizes attribute for responsive images
  className?: string;
}

export function OptimisedImage({
  src,
  alt,
  width,
  height,
  priority = false,
  sizes = '100vw',
  className,
}: OptimisedImageProps) {
  return (
    <picture>
      {/* AVIF — best compression, Chrome 85+, Firefox 93+, Safari 16+ */}
      <source
        type="image/avif"
        srcSet={`${src}-400.avif 400w, ${src}-800.avif 800w, ${src}-1200.avif 1200w`}
        sizes={sizes}
      />
      {/* WebP — good compression, all modern browsers */}
      <source
        type="image/webp"
        srcSet={`${src}-400.webp 400w, ${src}-800.webp 800w, ${src}-1200.webp 1200w`}
        sizes={sizes}
      />
      {/* Fallback JPEG */}
      <img
        src={`${src}-800.jpg`}
        srcSet={`${src}-400.jpg 400w, ${src}-800.jpg 800w, ${src}-1200.jpg 1200w`}
        sizes={sizes}
        alt={alt}
        width={width}
        height={height}
        // Prevents CLS — browser reserves space before image loads
        style={{ aspectRatio: `${width}/${height}` }}
        loading={priority ? 'eager' : 'lazy'}
        decoding={priority ? 'sync' : 'async'}
        fetchPriority={priority ? 'high' : 'low'}
        className={className}
      />
    </picture>
  );
}

// ─── Preload LCP image in HTML <head> ─────────────────────────────────────────

// index.html — preload the hero image so it starts downloading immediately
// This is the single most impactful LCP optimisation
```

```html
<!-- index.html -->
<head>
  <!-- Preload LCP image — must match the srcset the browser will pick -->
  <link
    rel="preload"
    as="image"
    href="/images/hero-800.avif"
    imagesrcset="/images/hero-400.avif 400w, /images/hero-800.avif 800w, /images/hero-1200.avif 1200w"
    imagesizes="(max-width: 600px) 100vw, (max-width: 1200px) 50vw, 800px"
    type="image/avif"
  />

  <!-- DNS prefetch for third-party origins used early in the page -->
  <link rel="dns-prefetch" href="https://analytics.example.com" />
  <link rel="preconnect" href="https://fonts.googleapis.com" crossorigin />

  <!-- Critical CSS inlined — eliminates render-blocking stylesheet round trip -->
  <style>
    /* Only above-fold styles; rest loaded asynchronously */
    body { margin: 0; font-family: system-ui, sans-serif; }
    .hero { height: 400px; background: #f0f0f0; }
    /* ... */
  </style>

  <!-- Non-critical CSS loaded asynchronously -->
  <link
    rel="preload"
    href="/assets/main.css"
    as="style"
    onload="this.onload=null;this.rel='stylesheet'"
  />
  <noscript><link rel="stylesheet" href="/assets/main.css" /></noscript>
</head>
```

### Pattern 4 — Interaction Performance (INP Optimisation)
```typescript
// Optimise long tasks that block the main thread and cause high INP

// ─── Yield to main thread between expensive operations ────────────────────────

function yieldToMain(): Promise<void> {
  // Use scheduler.yield() if available (Chrome 115+), fallback to setTimeout
  if ('scheduler' in window && 'yield' in (window as any).scheduler) {
    return (window as any).scheduler.yield();
  }
  return new Promise(resolve => setTimeout(resolve, 0));
}

// Break a long synchronous computation into yielding chunks
async function processLargeDataset(items: DataItem[]): Promise<ProcessedItem[]> {
  const results: ProcessedItem[] = [];
  const CHUNK_SIZE = 100;

  for (let i = 0; i < items.length; i += CHUNK_SIZE) {
    const chunk = items.slice(i, i + CHUNK_SIZE);
    const processed = chunk.map(transformItem);
    results.push(...processed);

    // Yield after each chunk — allows browser to process input events
    await yieldToMain();
  }

  return results;
}

// ─── Defer non-critical work until after interaction ─────────────────────────

class TaskScheduler {
  private queue: Array<() => void> = [];
  private isRunning = false;

  // Schedule non-critical work to run when browser is idle
  scheduleIdle(task: () => void): void {
    if ('requestIdleCallback' in window) {
      requestIdleCallback(() => task(), { timeout: 2000 });
    } else {
      setTimeout(task, 1);
    }
  }

  // Schedule after current frame — safe for DOM reads followed by writes
  scheduleAnimationFrame(task: () => void): void {
    requestAnimationFrame(task);
  }
}

// ─── Debounce expensive search input handler ─────────────────────────────────

import { useMemo, useCallback } from 'react';
import { debounce } from '@/utils/debounce';

export function useSearchHandler(onSearch: (q: string) => void) {
  // Debounce prevents search API call on every keystroke
  // 300ms delay — user perceives instant, server gets 1 call per word
  const debouncedSearch = useMemo(
    () => debounce(onSearch, 300),
    [onSearch]
  );

  return useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      debouncedSearch(e.target.value);
    },
    [debouncedSearch]
  );
}

// ─── Prevent CLS from dynamic content insertion ──────────────────────────────

// Reserve space before content loads — prevents layout shift
const NotificationBanner: React.FC = () => {
  const [message, setMessage] = useState<string | null>(null);

  return (
    // min-height prevents CLS when message appears/disappears
    <div style={{ minHeight: '48px', display: 'flex', alignItems: 'center' }}>
      {message && (
        <div className="banner">{message}</div>
      )}
    </div>
  );
};
```

### Pattern 5 — HTTP Caching and CDN Strategy
```typescript
// server/middleware/cache-headers.ts — Express middleware for cache control

import { Request, Response, NextFunction } from 'express';
import crypto from 'crypto';

export function cacheMiddleware(req: Request, res: Response, next: NextFunction) {
  const url = req.path;

  // Immutable hashed assets — cache forever (Vite adds hash to filenames)
  if (/\/assets\/[^/]+\.[a-f0-9]{8,}\.(js|css|woff2|png|jpg|avif|webp)$/.test(url)) {
    res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
    return next();
  }

  // Service worker — short cache to allow updates
  if (url === '/sw.js') {
    res.setHeader('Cache-Control', 'public, max-age=0, must-revalidate');
    return next();
  }

  // HTML pages — stale-while-revalidate for fast delivery + fresh content
  if (req.accepts('html')) {
    res.setHeader('Cache-Control', 'public, max-age=0, stale-while-revalidate=86400');
    return next();
  }

  // API responses — short cache with ETag for conditional requests
  if (url.startsWith('/api/')) {
    const etag = crypto
      .createHash('sha256')
      .update(res.locals.responseBody ?? '')
      .digest('hex')
      .slice(0, 16);
    res.setHeader('ETag', `"${etag}"`);
    res.setHeader('Cache-Control', 'private, max-age=60, stale-while-revalidate=300');
    return next();
  }

  next();
}
```

```nginx
# nginx.conf — pre-compressed Brotli/gzip serving + HTTP/2

server {
    listen 443 ssl http2;
    server_name app.example.com;

    root /var/www/dist;
    index index.html;

    # Serve pre-compressed Brotli files if available
    brotli_static on;
    gzip_static on;

    # Static assets — already hashed, cache forever
    location /assets/ {
        expires max;
        add_header Cache-Control "public, max-age=31536000, immutable";
        add_header Vary Accept-Encoding;
    }

    # SPA fallback — all routes serve index.html
    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control "public, max-age=0, stale-while-revalidate=86400";
    }

    # Security headers that affect performance
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy strict-origin-when-cross-origin;
}
```

### Pattern 6 — Lighthouse CI Performance Gate
```yaml
# .lighthouserc.json — Lighthouse CI configuration

{
  "ci": {
    "collect": {
      "url": [
        "http://localhost:4173/",
        "http://localhost:4173/payments",
        "http://localhost:4173/analytics"
      ],
      "numberOfRuns": 3,
      "settings": {
        "preset": "desktop",
        "throttlingMethod": "simulate",
        "screenEmulation": { "disabled": true }
      }
    },
    "assert": {
      "preset": "lighthouse:no-pwa",
      "assertions": {
        "categories:performance":    ["error", { "minScore": 0.90 }],
        "categories:accessibility":  ["error", { "minScore": 0.90 }],
        "first-contentful-paint":    ["error", { "maxNumericValue": 1800 }],
        "largest-contentful-paint":  ["error", { "maxNumericValue": 2500 }],
        "cumulative-layout-shift":   ["error", { "maxNumericValue": 0.1 }],
        "total-blocking-time":       ["error", { "maxNumericValue": 300 }],
        "interactive":               ["warn",  { "maxNumericValue": 3800 }],
        "uses-optimized-images":     ["warn",  {}],
        "render-blocking-resources": ["warn",  {}],
        "unused-javascript":         ["warn",  { "maxLength": 0 }]
      }
    },
    "upload": {
      "target": "temporary-public-storage"
    }
  }
}
```

```yaml
# .github/workflows/lighthouse.yml

name: Lighthouse Performance Gate
on:
  pull_request:
    branches: [main]

jobs:
  lighthouse:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - run: npm ci
      - run: npm run build

      - name: Start preview server
        run: npm run preview &
        # Wait for server to be ready
      - run: npx wait-on http://localhost:4173 --timeout 30000

      - name: Run Lighthouse CI
        uses: treosh/lighthouse-ci-action@v11
        with:
          configPath: .lighthouserc.json
          uploadArtifacts: true
          temporaryPublicStorage: true

      - name: Check bundle sizes
        run: |
          # Fail if main bundle exceeds performance budget
          BUNDLE_SIZE=$(du -sk dist/assets/*.js | sort -rn | head -1 | cut -f1)
          echo "Largest JS chunk: ${BUNDLE_SIZE}KB"
          if [ "$BUNDLE_SIZE" -gt 200 ]; then
            echo "ERROR: Largest JS chunk ${BUNDLE_SIZE}KB exceeds 200KB budget"
            exit 1
          fi
```

---

## Anti-Patterns

### 1. Importing Entire Libraries for Small Features
```typescript
// WRONG — imports all of lodash (~70KB gzipped)
import _ from 'lodash';
const unique = _.uniqBy(items, 'id');
```
```typescript
// RIGHT — import only the function you need (tree-shaken)
import uniqBy from 'lodash/uniqBy';
// Or use native: const unique = [...new Map(items.map(i => [i.id, i])).values()];
```

### 2. Blocking Render with Synchronous Scripts
```html
<!-- WRONG — blocks HTML parsing until script downloads and executes -->
<script src="/bundle.js"></script>
```
```html
<!-- RIGHT — async: download parallel, execute when ready -->
<script src="/bundle.js" async></script>
<!-- Or defer: download parallel, execute after HTML parsed (safer for DOM-dependent code) -->
<script src="/bundle.js" defer></script>
```

### 3. Unsized Images Causing CLS
```tsx
// WRONG — no width/height; browser can't reserve space → layout shift
<img src="/hero.jpg" alt="Hero" />
```
```tsx
// RIGHT — explicit dimensions prevent CLS
<img src="/hero.jpg" alt="Hero" width={800} height={400}
     style={{ aspectRatio: '2/1', width: '100%', height: 'auto' }} />
```

### 4. Eager Loading Everything
Loading all route components, all images, and all data on initial page load. Results in a massive initial bundle and slow LCP.

**Fix**: route-based code splitting, `loading="lazy"` for below-fold images, defer non-critical data fetches.

### 5. Optimising Without Measuring
Running "optimisations" (adding a CDN, compressing images) without measuring whether they actually improve Core Web Vitals for real users.

**Fix**: measure with CrUX (Chrome User Experience Report) or RUM (Real User Monitoring) before and after. Lighthouse lab scores are useful for regression detection but don't equal field performance.

### 6. Cache-Busting with Query Strings Instead of Content Hashes
```html
<!-- WRONG — some CDNs ignore query strings; cache invalidation unreliable -->
<script src="/bundle.js?v=1.2.3"></script>
```
```html
<!-- RIGHT — content hash in filename; cache-busted automatically on change -->
<script src="/assets/main-a3f9c2d1.js"></script>
```

---

## Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| LCP > 2.5s | Preload LCP image; improve TTFB; inline critical CSS |
| High CLS | Add width/height to images; reserve space for dynamic content |
| High INP | Break up long tasks; yield to main thread; debounce handlers |
| Large JS bundle | Code split by route; lazy-load below-fold components; tree-shake |
| Slow TTFB | CDN caching; server-side rendering; edge caching |
| Third-party script slow | Load async; use Partytown to run in Web Worker |
| Fonts causing CLS | `font-display: optional` or `swap` + size-adjust CSS property |
| API data causing skeleton flicker | Optimistic UI; skeleton placeholders with fixed height |
| Images slow | WebP/AVIF formats; responsive srcset; lazy load; CDN |
| Mobile performance worse than desktop | Test on real device or throttled Lighthouse; check JS parse time |

---

## Proficiency Levels

### Novice
- Knows what LCP, CLS, and INP measure
- Uses `loading="lazy"` on below-fold images
- Runs Lighthouse and can read the score
- Knows that render-blocking scripts slow page load

### Intermediate
- Configures code splitting by route in Vite/webpack
- Sets correct Cache-Control headers for hashed assets vs HTML
- Uses `<link rel="preload">` for LCP images
- Prevents CLS by setting image dimensions
- Analyses bundle with a visualiser; identifies heavy dependencies

### Advanced
- Implements INP optimisation (task splitting, yield, debounce)
- Configures Lighthouse CI as a PR gate with performance budgets
- Designs the full caching strategy (CDN, browser cache, stale-while-revalidate)
- Uses CrUX data to track field performance over time
- Distinguishes between lab data (Lighthouse) and field data (CrUX, RUM)

### Expert
- Designs RUM instrumentation that feeds CWV signals to observability platform
- Applies edge-side rendering (ESR) and streaming SSR for sub-second LCP
- Optimises for 3G/low-end devices: reduces JS parse time, uses Service Worker for offline
- Implements resource priorities (Priority Hints API) to control browser scheduler
- Builds automated performance regression detection tied to deploy pipeline

---

## AI Prompts

1. **LCP investigation**: "My LCP is 4.2s on mobile. The LCP element is a hero image 1200×600px served as JPEG. What are the top 3 optimisations I should make and what LCP improvement should I expect from each?"

2. **Bundle analysis**: "My Vite build produces a 1.2MB main JS chunk. Here is the rollup-visualizer output. Identify the largest dependencies and suggest how to split or replace them."

3. **CLS fix**: "My CLS score is 0.35. The main culprit is a notification banner that appears after 500ms and pushes content down. How do I fix this without removing the banner?"

4. **INP optimisation**: "My INP is 450ms on the payments form. The submit handler runs validation, calls an API, and updates a complex table. How do I break this into a pattern that achieves INP < 200ms?"

5. **Caching strategy**: "Design a complete HTTP caching strategy for a React SPA. I have: HTML entry point, hashed JS/CSS chunks, un-hashed images, API responses, and a service worker. What Cache-Control headers should each type have?"

---

## References

- web.dev/vitals — Core Web Vitals official documentation (Google)
- web.dev/performance — web performance learning path
- Lighthouse — developers.google.com/web/tools/lighthouse
- Chrome DevTools Performance panel — recording and flame graphs
- WebPageTest — webpagetest.org — real-device testing with filmstrips
- CrUX (Chrome User Experience Report) — field data by origin/URL
- Vite documentation — rollupOptions, manualChunks, build optimisation
- Partytown — github.com/BuilderIO/partytown — run third-party scripts in Web Worker
- Harry Roberts — CSS performance (csswizardry.com)
