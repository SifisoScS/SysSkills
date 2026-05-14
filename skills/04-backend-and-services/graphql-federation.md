---
name: GraphQL & Federation
slug: graphql-federation
category: 04-backend-and-services
proficiency: advanced
description: >
  Production-grade GraphQL: schema design (schema-first vs code-first), resolver
  patterns, N+1 elimination with DataLoader, Apollo Federation v2 (subgraphs,
  supergraph, @key/@shareable/@requires/@external directives), Apollo Router
  (Rust-based supergraph gateway), subscriptions over WebSocket/SSE, persisted
  queries, query complexity and depth limiting, CDN and response caching, and
  code generation (graphql-code-generator, gqlgen). Covers the full stack from
  single-service GraphQL API to a federated graph owned by multiple teams.
tags:
  - graphql
  - apollo-federation
  - apollo-router
  - dataloader
  - subgraph
  - supergraph
  - subscriptions
  - persisted-queries
  - gqlgen
  - code-generation
status: published
---

## Principles

### 1. The Schema Is the Contract — Design It for Consumers, Not the Database
GraphQL schemas are **product APIs**, not database views. Field names should
reflect domain language (`order` not `tbl_ord`). Types should model the
domain graph, not normalised table joins. A poorly designed schema leaks
implementation details and creates breaking changes. Design the schema first
with frontend consumers; let the resolver implementation follow.

### 2. Every Resolver Is a Function — Compose Them, Don't Nest Logic
A resolver is a function `(parent, args, context, info) → value`. The parent
field's resolved value is passed down the tree. Keep resolvers thin: they
fetch data, delegate to services, and return. Business logic belongs in a
service layer, not in resolvers. Nested resolvers enable the N+1 problem —
understanding when a resolver fires is prerequisite to batching correctly.

### 3. The N+1 Problem Is GraphQL's Most Common Production Bug
Fetching a list of 100 orders and resolving each order's `customer` field
fires 100 individual database queries — one per order. **DataLoader** batches
all `customer` lookups that occur within the same event-loop tick into a single
`WHERE id IN (...)` query. This is not an optimisation — it is a correctness
requirement for production GraphQL. Every list-typed field whose children have
nested resolvers needs a DataLoader.

### 4. Federation Is a Team Topology Tool as Much as a Technical One
Apollo Federation v2 lets each team own a **subgraph** — an independent GraphQL
service with its own schema and deployment pipeline. The **supergraph** composes
all subgraphs into a single schema at the **Apollo Router** layer, invisible to
clients. Teams extend each other's types with `@key` entity references instead
of direct service-to-service calls. The benefit is not just schema composition —
it is **independent deployability** of each team's API surface.

### 5. Introspection and Unbounded Queries Are Attack Surfaces in Production
Introspection exposes the full schema to any client — disable it in production
for public APIs. Unbounded queries (`{ users { orders { items { product { ... } } } } }`)
can trigger exponential resolver execution. **Query depth limiting** and
**query complexity scoring** (assign a cost to each field; reject queries above
a threshold) are mandatory before exposing GraphQL to untrusted clients.
**Persisted queries** (APQ or static query manifests) restrict execution to
pre-approved queries only — the strongest defence.

---

## Implementation Patterns

### Pattern A: Schema-First with Code Generation
Define the schema in `.graphql` SDL files. Run `graphql-code-generator` to
generate TypeScript types for resolvers and clients, or `gqlgen` for Go. The
generated types enforce that every resolver's return type matches the schema —
schema drift is a compile error, not a runtime surprise.

### Pattern B: DataLoader per Request Context
Instantiate a fresh DataLoader for each request (not as a singleton) so that
batching is scoped to one request and cache does not leak between users.
Inject DataLoader instances through the GraphQL context object so any resolver
can access them without prop-drilling.

### Pattern C: Apollo Federation v2 Entity Resolution
An entity is a type with a `@key` directive identifying its primary key field.
The owning subgraph defines the entity; other subgraphs can reference it with
`@external` fields. The Router calls the owning subgraph's `_entities` resolver
when it needs to hydrate referenced entities — the **representation** pattern.

### Pattern D: Subscription via `graphql-ws` + Redis Pub/Sub
Subscriptions require a stateful connection (WebSocket). For horizontal
scaling, publish subscription events through Redis Pub/Sub so all server
instances can fan out to connected clients regardless of which server hosts
their WebSocket connection.

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| No DataLoader on list-nested resolvers | N+1 queries; 100-item list fires 100 DB queries | Wrap every batched lookup in a per-request DataLoader |
| Introspection enabled in production | Schema fully exposed to attackers; enumeration of all types and fields | Disable introspection in prod; use persisted queries for trusted clients |
| Unbounded query depth/complexity | Crafted query triggers exponential resolver work; DoS | Add `graphql-depth-limit` + `graphql-query-complexity`; enforce at gateway |
| Resolver containing business logic | Logic duplicated as schema grows; untestable in isolation | Resolvers delegate to a service/use-case layer; test the layer directly |
| Returning `null` for errors instead of the `errors` array | Client cannot distinguish "not found" from "server error" from "unauthorised" | Use `GraphQLError` with `extensions.code`; never silently null on errors |
| Shared DataLoader singleton across requests | User A's cached data served to User B; auth bypass | Instantiate DataLoaders per request in the context factory |
| Federation subgraph exposing internal fields without `@inaccessible` | Internal implementation details visible in the supergraph public schema | Mark internal fields `@inaccessible`; use `@shareable` only for intentionally shared fields |
| Over-fetching on `_entities` query | Router fetches the same entity from the owning subgraph for every reference | Use `@provides` to declare that a referencing subgraph can supply a field without a round-trip |

---

## Code Templates

### Template 1 — TypeScript: Federation v2 Subgraph — Products Service
```typescript
// products-subgraph/src/schema.ts
import { buildSubgraphSchema } from '@apollo/subgraph';
import { gql } from 'graphql-tag';
import { createProductLoader } from './loaders';

// SDL — schema-first; code-gen produces TypeScript types
const typeDefs = gql`
  extend schema
    @link(url: "https://specs.apollo.dev/federation/v2.3",
          import: ["@key", "@shareable", "@inaccessible"])

  type Product @key(fields: "id") {
    id: ID!
    name: String!
    price: Float!
    inStock: Boolean!
    # Internal field — hidden from supergraph consumers
    supplierId: ID! @inaccessible
  }

  type Query {
    product(id: ID!): Product
    products(ids: [ID!]): [Product!]!
    featuredProducts: [Product!]!
  }
`;

const resolvers = {
  Query: {
    product: (_: unknown, { id }: { id: string }, ctx: Context) =>
      ctx.loaders.product.load(id),

    products: (_: unknown, { ids }: { ids: string[] }, ctx: Context) =>
      ctx.loaders.product.loadMany(ids),

    featuredProducts: (_: unknown, __: unknown, ctx: Context) =>
      ctx.productService.getFeatured(),
  },

  Product: {
    // Entity resolver — called by the Router to resolve @key references
    // from other subgraphs that reference Product by id
    __resolveReference(ref: { id: string }, ctx: Context) {
      return ctx.loaders.product.load(ref.id);
    },
  },
};

export const schema = buildSubgraphSchema({ typeDefs, resolvers });

// server/src/index.ts
import { ApolloServer } from '@apollo/server';
import { startStandaloneServer } from '@apollo/server/standalone';
import DataLoader from 'dataloader';
import { ProductService } from './services/ProductService';

interface Context {
  loaders: { product: DataLoader<string, Product> };
  productService: ProductService;
}

const server = new ApolloServer<Context>({ schema });

await startStandaloneServer(server, {
  listen: { port: 4001 },
  context: async () => {
    const productService = new ProductService();
    return {
      productService,
      loaders: {
        // Fresh DataLoader per request — never a singleton
        product: new DataLoader<string, Product>(async (ids) => {
          const products = await productService.findByIds([...ids]);
          const map = new Map(products.map(p => [p.id, p]));
          return ids.map(id => map.get(id) ?? new Error(`Product ${id} not found`));
        }),
      },
    };
  },
});
```

### Template 2 — TypeScript: Federation v2 Subgraph — Reviews Service (cross-entity reference)
```typescript
// reviews-subgraph/src/schema.ts
import { buildSubgraphSchema } from '@apollo/subgraph';
import { gql } from 'graphql-tag';

const typeDefs = gql`
  extend schema
    @link(url: "https://specs.apollo.dev/federation/v2.3",
          import: ["@key", "@external", "@requires", "@shareable"])

  # Reference Product from the products subgraph — only the @key field needed
  type Product @key(fields: "id") {
    id: ID! @external
    # @requires declares that the resolver needs this field from the owning subgraph
    name: String! @external
    reviews: [Review!]!
    averageRating: Float! @requires(fields: "name")   # name used in response enrichment
  }

  type Review @key(fields: "id") {
    id: ID!
    rating: Int!
    body: String!
    author: User!
  }

  type User @key(fields: "id") {
    id: ID!
    displayName: String! @shareable
  }

  type Query {
    review(id: ID!): Review
  }
`;

const resolvers = {
  Product: {
    __resolveReference: (ref: { id: string }) => ref,  // Router provides the entity

    reviews: (product: { id: string }, _: unknown, ctx: Context) =>
      ctx.loaders.reviewsByProduct.load(product.id),

    averageRating: async (product: { id: string; name: string }, _: unknown, ctx: Context) => {
      const reviews = await ctx.loaders.reviewsByProduct.load(product.id);
      if (!reviews.length) return 0;
      const avg = reviews.reduce((sum, r) => sum + r.rating, 0) / reviews.length;
      // `product.name` is available here because of @requires(fields: "name")
      console.log(`Average rating for "${product.name}": ${avg}`);
      return avg;
    },
  },

  Review: {
    __resolveReference: (ref: { id: string }, ctx: Context) =>
      ctx.loaders.review.load(ref.id),
  },

  Query: {
    review: (_: unknown, { id }: { id: string }, ctx: Context) =>
      ctx.loaders.review.load(id),
  },
};

export const schema = buildSubgraphSchema({ typeDefs, resolvers });
```

### Template 3 — Go: `gqlgen` Schema-First Server with DataLoader
```go
// graph/schema.graphqls
// type Query { product(id: ID!): Product }
// type Product { id: ID!, name: String!, category: Category! }
// type Category { id: ID!, name: String! }

// graph/resolver.go — generated skeleton filled in by developer
package graph

import (
    "context"
    "github.com/graph-gophers/dataloader/v7"
)

type Resolver struct {
    productSvc  ProductService
    categorySvc CategoryService
}

// ProductResolver — field-level resolvers for Product
func (r *productResolver) Category(ctx context.Context, obj *model.Product) (*model.Category, error) {
    // DataLoader is injected via context — one batch per request event loop tick
    loader := ctx.Value(categoryLoaderKey).(*dataloader.Loader[string, *model.Category])
    thunk := loader.Load(ctx, obj.CategoryID)
    return thunk()
}

// Middleware: attach per-request DataLoaders to context
func DataLoaderMiddleware(categorySvc CategoryService, next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        loader := dataloader.NewBatchedLoader(
            func(ctx context.Context, ids []string) []*dataloader.Result[*model.Category] {
                cats, err := categorySvc.FindByIDs(ctx, ids)
                results := make([]*dataloader.Result[*model.Category], len(ids))
                catMap := make(map[string]*model.Category, len(cats))
                for _, c := range cats {
                    catMap[c.ID] = c
                }
                for i, id := range ids {
                    if err != nil {
                        results[i] = &dataloader.Result[*model.Category]{Error: err}
                    } else if cat, ok := catMap[id]; ok {
                        results[i] = &dataloader.Result[*model.Category]{Data: cat}
                    } else {
                        results[i] = &dataloader.Result[*model.Category]{
                            Error: fmt.Errorf("category %s not found", id),
                        }
                    }
                }
                return results
            },
            dataloader.WithBatchCapacity[string, *model.Category](100),
        )
        ctx := context.WithValue(r.Context(), categoryLoaderKey, loader)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

// main.go — wire up gqlgen server with middleware
func main() {
    srv := handler.NewDefaultServer(generated.NewExecutableSchema(
        generated.Config{Resolvers: &graph.Resolver{
            productSvc:  NewProductService(),
            categorySvc: NewCategoryService(),
        }},
    ))
    // Query complexity limit: max 100 points; each field costs 1, lists cost children * 10
    srv.Use(extension.FixedComplexityLimit(100))
    // Introspection disabled in production
    if os.Getenv("ENV") == "production" {
        srv.Use(extension.Introspection{})  // disable via middleware
    }
    http.Handle("/query", DataLoaderMiddleware(NewCategoryService(), srv))
    log.Fatal(http.ListenAndServe(":8080", nil))
}
```

### Template 4 — Apollo Router: Supergraph Config + Router YAML
```yaml
# supergraph.yaml — used by rover to compose the supergraph SDL
federation_version: =2.3.0
subgraphs:
  products:
    routing_url: http://products-service:4001/graphql
    schema:
      subgraph_url: http://products-service:4001/graphql
  reviews:
    routing_url: http://reviews-service:4002/graphql
    schema:
      subgraph_url: http://reviews-service:4002/graphql
  users:
    routing_url: http://users-service:4003/graphql
    schema:
      subgraph_url: http://users-service:4003/graphql
```

```yaml
# router.yaml — Apollo Router configuration
supergraph:
  listen: 0.0.0.0:4000
  introspection: false          # disable in production

cors:
  origins: ["https://app.company.com"]

limits:
  max_depth: 12                 # reject queries deeper than 12 levels
  max_aliases: 30               # prevent alias-based amplification
  max_tokens: 10000             # rough query size limit

# Persisted queries — only registered queries may execute
persisted_queries:
  enabled: true
  safelist:
    enabled: true               # reject unregistered queries entirely
    require_id: true

telemetry:
  tracing:
    propagation:
      trace_context: true       # W3C TraceContext forwarded to subgraphs
    otlp:
      endpoint: "http://otel-collector:4317"
      protocol: grpc
  metrics:
    otlp:
      endpoint: "http://otel-collector:4317"

# Per-subgraph timeouts
traffic_shaping:
  subgraphs:
    products:
      timeout: 2s
    reviews:
      timeout: 3s
```

```bash
# Compose supergraph SDL and start Router
rover supergraph compose --config supergraph.yaml > supergraph.graphql
./router --supergraph supergraph.graphql --config router.yaml
```

### Template 5 — TypeScript: Subscriptions via `graphql-ws` + Redis Pub/Sub
```typescript
// subscriptions-server/src/index.ts
import { createServer } from 'http';
import { makeExecutableSchema } from '@graphql-tools/schema';
import { WebSocketServer } from 'ws';
import { useServer } from 'graphql-ws/lib/use/ws';
import { PubSub } from 'graphql-subscriptions';
import { RedisPubSub } from 'graphql-redis-subscriptions';
import Redis from 'ioredis';

// Use Redis-backed PubSub for horizontal scaling (multiple server instances)
const pubsub = new RedisPubSub({
  publisher:  new Redis({ host: 'redis', port: 6379 }),
  subscriber: new Redis({ host: 'redis', port: 6379 }),
});

const ORDER_UPDATED = 'ORDER_UPDATED';

const typeDefs = `
  type Subscription {
    orderUpdated(orderId: ID!): OrderEvent!
  }
  type OrderEvent {
    orderId: ID!
    status: String!
    updatedAt: String!
  }
  type Mutation {
    updateOrderStatus(orderId: ID!, status: String!): OrderEvent!
  }
`;

const resolvers = {
  Subscription: {
    orderUpdated: {
      subscribe: (_: unknown, { orderId }: { orderId: string }) =>
        pubsub.asyncIterator(`${ORDER_UPDATED}.${orderId}`),
      resolve: (payload: OrderEvent) => payload,
    },
  },
  Mutation: {
    updateOrderStatus: async (
      _: unknown,
      { orderId, status }: { orderId: string; status: string }
    ) => {
      const event: OrderEvent = { orderId, status, updatedAt: new Date().toISOString() };
      // Publish to Redis — all WS server instances receive and fan out to subscribers
      await pubsub.publish(`${ORDER_UPDATED}.${orderId}`, event);
      return event;
    },
  },
};

const schema = makeExecutableSchema({ typeDefs, resolvers });
const httpServer = createServer();
const wsServer = new WebSocketServer({ server: httpServer, path: '/graphql' });

useServer(
  {
    schema,
    context: async (ctx) => ({
      // Validate auth token from connection params before accepting subscription
      userId: await validateToken(ctx.connectionParams?.authorization as string),
    }),
    onConnect: async (ctx) => {
      if (!ctx.connectionParams?.authorization) {
        throw new Error('Unauthorised: missing authorization param');
      }
    },
  },
  wsServer
);

httpServer.listen(4000, () => console.log('GraphQL WS server on :4000/graphql'));
```

### Template 6 — TypeScript: Query Complexity + Depth Limiting + Persisted Queries
```typescript
// security-middleware/src/index.ts
import { ApolloServer } from '@apollo/server';
import depthLimit from 'graphql-depth-limit';
import {
  createComplexityLimitRule,
  simpleEstimator,
  fieldExtensionsEstimator,
} from 'graphql-query-complexity';
import { createHash } from 'crypto';

// --- Query Depth Limiting ---
const depthLimitRule = depthLimit(
  10,    // max nesting depth
  { ignore: ['__schema', '__type'] },   // allow introspection in development
  (depths) => {
    console.warn('Query depth:', JSON.stringify(depths));
  }
);

// --- Query Complexity Scoring ---
// Each scalar field costs 1; each object field costs 1;
// list fields multiply children by expected size.
const complexityRule = createComplexityLimitRule(1000, {
  estimators: [
    // Field-level override: resolver declares its cost via schema extensions
    fieldExtensionsEstimator(),
    // Default: scalars cost 1, objects cost 1, lists cost args.first ?? 10
    simpleEstimator({ defaultComplexity: 1 }),
  ],
  formatErrorMessage: (cost) =>
    `Query too complex (${cost}); maximum allowed complexity is 1000`,
  createError: (max, actual) =>
    new GraphQLError(`Complexity ${actual} exceeds limit ${max}`, {
      extensions: { code: 'QUERY_TOO_COMPLEX', complexity: actual, maxComplexity: max },
    }),
});

// --- Automatic Persisted Queries (APQ) ---
// Client sends: { extensions: { persistedQuery: { sha256Hash, version: 1 } } }
// On cache miss, client resends with full query; server caches for future hits.
// For maximum security, combine with an allowlist (only pre-registered queries).
const queryCache = new Map<string, string>();

function buildQueryCachePlugin() {
  return {
    async requestDidStart() {
      return {
        async didResolveOperation({ request, document }: any) {
          const hash = request.extensions?.persistedQuery?.sha256Hash;
          if (hash) {
            const cached = queryCache.get(hash);
            if (cached) {
              request.query = cached;
            } else if (request.query) {
              // Verify the hash matches the provided query before caching
              const computedHash = createHash('sha256')
                .update(request.query)
                .digest('hex');
              if (computedHash === hash) {
                queryCache.set(hash, request.query);
              }
            }
          }
        },
      };
    },
  };
}

const server = new ApolloServer({
  schema,
  validationRules: [depthLimitRule, complexityRule],
  plugins: [buildQueryCachePlugin()],
  introspection: process.env.NODE_ENV !== 'production',
  formatError: (formattedError, error) => {
    // Never leak internal error details to clients
    if (process.env.NODE_ENV === 'production') {
      return {
        message: formattedError.message,
        extensions: { code: formattedError.extensions?.code ?? 'INTERNAL_SERVER_ERROR' },
      };
    }
    return formattedError;
  },
});
```

---

## Decision Matrix

| Decision | Option A | Option B | Guidance |
|---|---|---|---|
| **Schema design approach** | Schema-first (SDL + codegen) | Code-first (programmatic schema) | Schema-first for multi-team; SDL is the canonical contract; code-first for rapid iteration in solo projects |
| **Federation gateway** | Apollo Router (Rust, high performance) | Apollo Gateway (Node.js, legacy) | Router for production — 8× throughput; Gateway only if existing tooling depends on it |
| **Subscription transport** | `graphql-ws` (WebSocket, standard) | SSE (Server-Sent Events) | `graphql-ws` for bidirectional; SSE for push-only over HTTP/2 CDN-compatible connections |
| **Caching** | Apollo Server response caching (`@cacheControl`) | CDN (Cloudflare, Fastly) on GET requests | `@cacheControl` for per-field TTLs; CDN for public cacheable queries via GET + query hash |
| **Auth in federated graph** | JWT validated at Router; user context forwarded | Each subgraph validates independently | Validate at Router; forward as signed header; avoids repeated validation in every subgraph |
| **Query allow-listing** | APQ (Automatic Persisted Queries) + safelist | Static query manifests (generated at build time) | APQ for flexibility; static manifests for maximum security (CI rejects unregistered queries) |
| **N+1 prevention** | DataLoader (per-request, per-type) | JOINs in the root resolver | DataLoader is composable and works with any DB; JOINs couple the resolver to a specific schema shape |
| **When NOT to use GraphQL** | Simple REST CRUD with no flexibility requirements | File upload / streaming binary data | REST is simpler for fixed-shape APIs; GraphQL multipart uploads are awkward |

---

## Proficiency Levels

### Novice
- Understands the difference between GraphQL queries, mutations, and subscriptions
- Reads a schema SDL; knows Object types, scalars, non-null (`!`), and list types
- Can write a basic resolver function and connect it to a data source
- Runs a query in GraphQL Playground / Apollo Sandbox

### Intermediate
- Identifies and fixes N+1 queries using DataLoader
- Designs a schema that reflects domain language rather than database shape
- Sets up Apollo Server with authentication context and error formatting
- Writes Federation v2 subgraph with `@key` entity resolution
- Applies depth limiting and query complexity rules
- Generates TypeScript types from SDL with `graphql-code-generator`

### Advanced
- Designs and composes a multi-subgraph federation with `@requires`, `@provides`, `@external`
- Configures Apollo Router with traffic shaping, telemetry, and persisted query safelist
- Implements type-safe subscriptions with Redis Pub/Sub for horizontal scaling
- Optimises resolver performance with field-level caching (`@cacheControl`) and CDN GET queries
- Uses `rover` CLI for schema composition, checks, and schema registry publication
- Instruments Apollo Router with OTel traces forwarded to subgraphs for end-to-end tracing

### Expert
- Designs federation governance: schema ownership, breaking-change detection in CI, registry
- Implements custom Apollo Router plugins (Rhai scripting or external coprocessors) for auth/transforms
- Architects multi-region federated graph with subgraph replica routing and latency-based selection
- Evaluates GraphQL Fusion (next-gen composition) vs Federation v2 for a specific org structure
- Optimises DataLoader batching beyond simple key-based loads (cursor pagination batching, multi-key)
- Designs a query cost model (field weights, list multipliers) tailored to specific data access patterns

---

## AI Prompts

```
You are a GraphQL architect. I have a REST API with three services: Products,
Reviews, and Orders. I want to expose a unified GraphQL API to our React
frontend. Should I use Apollo Federation or a monolithic GraphQL server?
Explain the decision criteria, then show me the Federation v2 schema design
for a query like { order(id: "123") { id total products { name reviews { rating } } } }
and which subgraph owns each type.
```

```
Acting as a GraphQL performance expert: my Apollo Server is running 500 RPS
and I see p99 latency of 800 ms. A slow-query log shows that product list
queries trigger hundreds of category lookups. Explain the N+1 problem in
this context, show the DataLoader fix with correct batching, and describe
how to verify with query tracing that the batching is working.
```

```
Explain Apollo Federation v2 @requires and @provides directives with a
concrete example. I have a Products subgraph with Product.weight and a
Shipping subgraph that needs Product.weight to calculate shippingCost.
Show the exact schema SDL for both subgraphs, the resolver for shippingCost,
and explain what happens at the Router level when this query executes.
```

```
Design a query complexity scoring model for a social graph API where users
have posts, posts have comments, and comments have replies (3 levels of
nesting). Assign field costs, list multipliers, and a maximum complexity
threshold. Show the graphql-query-complexity configuration and explain
why this prevents a query like { users { posts { comments { replies { author { posts { ... } } } } } } }.
```

```
I need to add real-time order status updates to a federated GraphQL API.
The updates originate from a Kafka topic. Design the subscription flow:
Kafka consumer → Redis Pub/Sub → GraphQL subscription resolver → WebSocket
client. Show the TypeScript code for the Kafka-to-Redis bridge and the
graphql-ws subscription resolver. How does this scale to 10,000 concurrent
subscribers?
```

---

## References

- **GraphQL spec** — https://spec.graphql.org — the authoritative language specification
- **Apollo Federation v2 docs** — https://www.apollographql.com/docs/federation/
- **Apollo Router** — https://www.apollographql.com/docs/router/ — Rust supergraph gateway
- **graphql-code-generator** — https://the-guild.dev/graphql/codegen — TypeScript type generation
- **gqlgen** — https://gqlgen.com — Go schema-first GraphQL library
- **DataLoader** — https://github.com/graphql/dataloader — batching and caching
- **graphql-query-complexity** — https://github.com/slicknode/graphql-query-complexity
- **graphql-depth-limit** — https://github.com/stems/graphql-depth-limit
- **graphql-ws** — https://github.com/enisdenjo/graphql-ws — WebSocket subscription protocol
- **graphql-redis-subscriptions** — https://github.com/davidyaha/graphql-redis-subscriptions
- **Rover CLI** — https://www.apollographql.com/docs/rover/ — schema registry and composition
- **GraphQL Fusion** — https://chillicream.com/docs/fusion — next-gen open-source federation
- **The Guild** — https://the-guild.dev — framework-agnostic GraphQL tooling ecosystem
- **SysSkills cross-reference** — `api-design-strategy`, `event-driven-architecture-cqrs`,
  `distributed-tracing-debugging`, `resilience-fault-tolerance-patterns`
