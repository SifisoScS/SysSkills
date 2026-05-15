---
name: Search & Vector Databases
slug: search-vector-databases
category: 05-data-and-persistence
proficiency: advanced
description: >
  Design and operate search and vector retrieval systems: Elasticsearch query DSL
  (bool, nested, aggregations), index design (mappings, analyzers, sharding),
  relevance tuning (BM25, function_score), pgvector HNSW index, embedding
  generation and cosine similarity queries, RAG (Retrieval-Augmented Generation)
  pipeline architecture, hybrid search combining BM25 and vector similarity, and
  Qdrant for pure-vector workloads.
tags:
  - elasticsearch
  - vector-database
  - pgvector
  - qdrant
  - full-text-search
  - rag
  - embeddings
  - hybrid-search
  - bm25
  - hnsw
  - semantic-search
status: complete
---

## Principles

### Search vs Vector Retrieval

| Dimension | Full-Text Search (BM25) | Vector Search (ANN) |
|---|---|---|
| Matches | Exact terms, stemmed forms, synonyms | Semantic meaning, regardless of exact words |
| Query | "payment gateway" → finds docs with those words | "how do I collect money online" → finds semantically similar docs |
| Index | Inverted index (term → doc IDs) | HNSW / IVF vector index |
| Tuning | Boost fields, analyzers, synonyms | Embedding model quality, index parameters |
| Recall pattern | Precise for known terminology | High recall for paraphrase/concept queries |
| Best for | Product search, log search, exact match | Semantic Q&A, recommendation, similarity |

**Hybrid search** combines both: BM25 for keyword precision + vector for semantic recall. The scores are merged via Reciprocal Rank Fusion (RRF) or weighted sum.

### Inverted Index (Elasticsearch/Lucene)
```
Text: "Payment gateway integration guide"
          ↓ (analyzer: lowercase → tokenise → stem)
Tokens: [payment, gatewai, integr, guid]

Inverted index:
  payment  → [doc1, doc3, doc7]
  gatewai  → [doc1, doc5]
  integr   → [doc1, doc2, doc7, doc9]
  guid     → [doc1, doc4]

Query "payment integration":
  payment ∩ integr → doc1, doc7  (both terms present)
  BM25 score = TF-IDF weighted by field length normalisation
```

### Vector Embeddings
An embedding model maps text (or image, audio) to a dense vector in N-dimensional space. Semantically similar content maps to nearby vectors (cosine similarity or dot product).

```
"payment failed"  → [0.21, -0.43, 0.87, …]  (1536 dims for text-embedding-3-small)
"transaction error" → [0.19, -0.41, 0.84, …]  ← nearby vector
"banana smoothie"  → [0.98,  0.31, -0.12, …]  ← distant vector
```

**Approximate Nearest Neighbour (ANN) algorithms:**
- **HNSW** (Hierarchical Navigable Small World) — graph-based; best recall/speed; used by pgvector, Qdrant, Weaviate
- **IVF** (Inverted File Index) — cluster-based; lower memory; used by Faiss
- **Flat (brute-force)** — exact; O(N); only feasible for N < 100k

### RAG — Retrieval-Augmented Generation
```
User question
     ↓
[1] Embed question → query vector
     ↓
[2] ANN search over knowledge base → top-K relevant chunks
     ↓
[3] Build prompt: system_prompt + chunks + question
     ↓
[4] LLM generates answer grounded in retrieved context
     ↓
Answer (with citations to source chunks)
```
RAG reduces hallucination, keeps knowledge up to date without fine-tuning, and provides citations. The quality ceiling is retrieval quality — garbage retrieval → garbage answer.

### Elasticsearch Shard Design
- 1 shard ≈ one Lucene index; max recommended shard size: 50 GB
- Too many small shards → overhead; too few large shards → slow rebalancing
- **Primary shards** fixed at index creation; **replica shards** adjustable
- Rule of thumb: aim for shards of 10–50 GB; size per node ≤ 200 GB total

---

## Implementation Patterns

### 1. Elasticsearch Index Mapping
Explicit mappings prevent field type inference errors and control analyzer behaviour. Disable `dynamic: true` on production indices to prevent accidental field creation.

### 2. bool Query + Aggregations
The `bool` query combines `must` (AND, affects score), `filter` (AND, no score), `should` (OR, boosts score), `must_not` (NOT). Use `filter` for facets and date ranges — faster because they are cached and don't compute scores.

### 3. Relevance Tuning: function_score
`function_score` wraps a base query and multiplies/adds scores from field values, decay functions (recency), and scripted expressions. Use for business-rule boosting (promoted products, recent documents).

### 4. pgvector — Embedded Vector Search in PostgreSQL
Add vector similarity search to an existing PostgreSQL instance. Best for: existing PostgreSQL workloads adding semantic search, < 1M vectors, latency tolerance ≥ 10 ms.

### 5. Qdrant — Dedicated Vector Database
Rust-based; HNSW with payload filtering; supports named vectors (image + text multi-modal). Best for: pure vector workloads, > 1M vectors, sub-10 ms latency requirement, payload-filtered ANN.

### 6. Hybrid Search with RRF
Reciprocal Rank Fusion merges ranked lists without needing score normalisation. Score for doc d = Σ 1/(k + rank_i(d)) where k=60 is a smoothing constant. Higher combined rank → higher RRF score.

---

## Anti-Patterns

| Anti-Pattern | Why It Fails | Correction |
|---|---|---|
| **`dynamic: true` on production index** | Accidental field creation; wrong types inferred (e.g., numeric string → long) | Set `dynamic: strict`; define all fields explicitly |
| **Too many shards (over-sharding)** | Coordination overhead; slow search across 1000 shards | 1 shard per 10–50 GB of data; monitor shard count |
| **`text` field for aggregations** | `text` fields are analysed; not available for bucket aggs | Add `keyword` subfield (`fields: {keyword: {type: keyword}}`) |
| **Embedding the whole document** | Chunk boundary cuts important context; poor recall | Chunk at natural boundaries (sentence, paragraph); overlap 10–20% |
| **Not filtering before vector search** | ANN over 10M vectors when 99% filtered out | Apply payload filter inside ANN (Qdrant) or pre-filter IDs then ANN |
| **Using cosine on non-normalised vectors** | Cosine ≡ dot product only when vectors are normalised | Normalise embeddings at storage time; use dot product index |
| **Embedding at query time without caching** | Embedding model call adds 50–200 ms latency | Cache query embeddings by hash of query text (Redis, 5-min TTL) |
| **Using `_id` for joins** | Elasticsearch is not relational; nested loops are expensive | Denormalise; use nested objects or parent/child only for specific patterns |
| **Not monitoring index lag (Elasticsearch)** | Writes buffered in index buffer; search sees stale data | Monitor `indexing_rate` and `refresh_interval`; tune for your freshness requirement |
| **HNSW `ef_construction` too low** | Poor recall at build time; can't be fixed without reindex | Set `ef_construction ≥ 100`; `m = 16` (pgvector default); verify recall with ground truth |

---

## Code Templates

### Template 1 — Elasticsearch Index Mapping + Settings

```json
// PUT /payments-search
{
  "settings": {
    "number_of_shards": 3,
    "number_of_replicas": 1,
    "refresh_interval": "5s",
    "analysis": {
      "analyzer": {
        "payment_analyzer": {
          "type": "custom",
          "tokenizer": "standard",
          "filter": ["lowercase", "asciifolding", "payment_synonyms", "english_stemmer"]
        },
        "autocomplete_analyzer": {
          "type": "custom",
          "tokenizer": "standard",
          "filter": ["lowercase", "autocomplete_filter"]
        },
        "autocomplete_search_analyzer": {
          "type": "custom",
          "tokenizer": "standard",
          "filter": ["lowercase"]
        }
      },
      "filter": {
        "payment_synonyms": {
          "type": "synonym",
          "synonyms": [
            "cc, credit card, card",
            "EFT, bank transfer, wire transfer",
            "tx, transaction, payment"
          ]
        },
        "english_stemmer": {
          "type": "stemmer",
          "language": "english"
        },
        "autocomplete_filter": {
          "type": "edge_ngram",
          "min_gram": 2,
          "max_gram": 20
        }
      }
    }
  },
  "mappings": {
    "dynamic": "strict",
    "properties": {
      "id":          { "type": "keyword" },
      "merchant_id": { "type": "keyword" },
      "status":      { "type": "keyword" },
      "amount":      { "type": "scaled_float", "scaling_factor": 100 },
      "currency":    { "type": "keyword" },
      "created_at":  { "type": "date" },
      "reference": {
        "type": "text",
        "analyzer": "payment_analyzer",
        "fields": {
          "keyword": { "type": "keyword", "ignore_above": 256 },
          "suggest": { "type": "text", "analyzer": "autocomplete_analyzer",
                       "search_analyzer": "autocomplete_search_analyzer" }
        }
      },
      "description": {
        "type": "text",
        "analyzer": "payment_analyzer"
      },
      "metadata": {
        "type": "object",
        "dynamic": false
      }
    }
  }
}
```

---

### Template 2 — Elasticsearch Query DSL (Go)

```go
// internal/search/payments.go
package search

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"

	"github.com/elastic/go-elasticsearch/v8"
	"github.com/elastic/go-elasticsearch/v8/typedapi/types"
	"github.com/elastic/go-elasticsearch/v8/typedapi/types/enums/sortorder"
)

type PaymentSearchParams struct {
	Query      string
	MerchantID string
	Status     []string
	MinAmount  *float64
	MaxAmount  *float64
	From       string // ISO date
	To         string
	Page       int
	PageSize   int
}

type SearchResult struct {
	Total    int64
	Payments []PaymentHit
}

type PaymentHit struct {
	ID       string  `json:"id"`
	Score    float64 `json:"_score"`
	Source   map[string]any `json:"_source"`
}

func SearchPayments(ctx context.Context, es *elasticsearch.TypedClient, p PaymentSearchParams) (*SearchResult, error) {
	must := []types.Query{}
	filter := []types.Query{}

	// Full-text match on reference + description
	if p.Query != "" {
		must = append(must, types.Query{
			MultiMatch: &types.MultiMatchQuery{
				Query:  p.Query,
				Fields: []string{"reference^2", "description"},
				Type:   &[]types.TextQueryType{types.TextquerytypeBestFields}[0],
			},
		})
	}

	// Keyword filters (do not affect score; cached)
	if p.MerchantID != "" {
		filter = append(filter, types.Query{
			Term: map[string]types.TermQuery{
				"merchant_id": {Value: p.MerchantID},
			},
		})
	}
	if len(p.Status) > 0 {
		filter = append(filter, types.Query{
			Terms: &types.TermsQuery{
				TermsQuery: map[string]types.TermsQueryField{
					"status": p.Status,
				},
			},
		})
	}
	if p.From != "" || p.To != "" {
		rq := types.DateRangeQuery{}
		if p.From != "" { rq.Gte = &p.From }
		if p.To   != "" { rq.Lte = &p.To }
		filter = append(filter, types.Query{
			Range: map[string]types.RangeQuery{"created_at": rq},
		})
	}
	if p.MinAmount != nil || p.MaxAmount != nil {
		nrq := types.NumberRangeQuery{}
		if p.MinAmount != nil { gte := types.Float64(*p.MinAmount); nrq.Gte = &gte }
		if p.MaxAmount != nil { lte := types.Float64(*p.MaxAmount); nrq.Lte = &lte }
		filter = append(filter, types.Query{
			Range: map[string]types.RangeQuery{"amount": nrq},
		})
	}

	from := p.Page * p.PageSize
	resp, err := es.Search().
		Index("payments-search").
		Request(&types.SearchRequest{
			Query: &types.Query{
				Bool: &types.BoolQuery{Must: must, Filter: filter},
			},
			From: &from,
			Size: &p.PageSize,
			Sort: []types.SortCombinations{
				types.SortOptions{SortOptions: map[string]types.FieldSort{
					"_score":     {Order: &sortorder.Desc},
					"created_at": {Order: &sortorder.Desc},
				}},
			},
			Highlight: &types.Highlight{
				Fields: map[string]types.HighlightField{
					"reference":   {},
					"description": {},
				},
			},
		}).
		Do(ctx)
	if err != nil {
		return nil, fmt.Errorf("elasticsearch search: %w", err)
	}

	hits := make([]PaymentHit, 0, len(resp.Hits.Hits))
	for _, h := range resp.Hits.Hits {
		var src map[string]any
		json.Unmarshal(h.Source_, &src)
		hits = append(hits, PaymentHit{
			ID:     *h.Id_,
			Score:  float64(*h.Score_),
			Source: src,
		})
	}

	return &SearchResult{
		Total:    resp.Hits.Total.Value,
		Payments: hits,
	}, nil
}
```

---

### Template 3 — pgvector: HNSW Index + Similarity Search (SQL + Go)

```sql
-- Enable extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Document chunks table with embedding
CREATE TABLE document_chunks (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id UUID        NOT NULL REFERENCES documents(id),
    chunk_index INT         NOT NULL,
    content     TEXT        NOT NULL,
    embedding   vector(1536) NOT NULL,    -- OpenAI text-embedding-3-small dimension
    metadata    JSONB,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- HNSW index: build once, query fast
-- m: edges per node (16 default); ef_construction: build-time recall (64–200)
CREATE INDEX idx_chunks_embedding_hnsw
    ON document_chunks
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 100);

-- Query: find top-5 semantically similar chunks
-- Set ef_search at session level for recall/speed trade-off
SET hnsw.ef_search = 100;

SELECT
    dc.id,
    dc.content,
    dc.metadata,
    1 - (dc.embedding <=> $1::vector) AS similarity   -- cosine similarity (1=identical)
FROM document_chunks dc
JOIN documents d ON d.id = dc.document_id
WHERE d.tenant_id = $2                                  -- pre-filter by tenant
  AND dc.metadata->>'category' = $3                    -- payload filter
ORDER BY dc.embedding <=> $1::vector                   -- <=> = cosine distance (lower = closer)
LIMIT 5;

-- Hybrid search: combine FTS rank + vector similarity
WITH fts AS (
    SELECT id, ts_rank(search_vector, query) AS fts_score
    FROM document_chunks,
         to_tsquery('english', $4) AS query
    WHERE search_vector @@ query
    LIMIT 100
),
vec AS (
    SELECT id, 1 - (embedding <=> $1::vector) AS vec_score
    FROM document_chunks
    ORDER BY embedding <=> $1::vector
    LIMIT 100
),
rrf AS (
    SELECT
        COALESCE(fts.id, vec.id) AS id,
        1.0 / (60 + ROW_NUMBER() OVER (ORDER BY fts_score DESC NULLS LAST))  AS fts_rrf,
        1.0 / (60 + ROW_NUMBER() OVER (ORDER BY vec_score DESC NULLS LAST))  AS vec_rrf
    FROM fts
    FULL OUTER JOIN vec ON fts.id = vec.id
)
SELECT dc.id, dc.content, rrf.fts_rrf + rrf.vec_rrf AS rrf_score
FROM rrf
JOIN document_chunks dc ON dc.id = rrf.id
ORDER BY rrf_score DESC
LIMIT 10;
```

```go
// internal/search/vector.go — embedding + pgvector search in Go
package search

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/pgvector/pgvector-go"
	openai "github.com/sashabaranov/go-openai"
)

type VectorSearcher struct {
	db     *pgxpool.Pool
	openai *openai.Client
}

func (v *VectorSearcher) Embed(ctx context.Context, text string) (pgvector.Vector, error) {
	resp, err := v.openai.CreateEmbeddings(ctx, openai.EmbeddingRequest{
		Input: []string{text},
		Model: openai.SmallEmbedding3,
	})
	if err != nil {
		return pgvector.Vector{}, fmt.Errorf("embed: %w", err)
	}
	floats := make([]float32, len(resp.Data[0].Embedding))
	for i, f := range resp.Data[0].Embedding {
		floats[i] = float32(f)
	}
	return pgvector.NewVector(floats), nil
}

type Chunk struct {
	ID         string
	Content    string
	Similarity float64
}

func (v *VectorSearcher) SimilarChunks(
	ctx context.Context,
	query string,
	tenantID string,
	topK int,
) ([]Chunk, error) {
	embedding, err := v.Embed(ctx, query)
	if err != nil {
		return nil, err
	}

	rows, err := v.db.Query(ctx, `
		SET hnsw.ef_search = 100;
		SELECT id, content, 1 - (embedding <=> $1) AS similarity
		FROM document_chunks
		WHERE tenant_id = $2
		ORDER BY embedding <=> $1
		LIMIT $3`,
		embedding, tenantID, topK,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var chunks []Chunk
	for rows.Next() {
		var c Chunk
		if err := rows.Scan(&c.ID, &c.Content, &c.Similarity); err != nil {
			return nil, err
		}
		chunks = append(chunks, c)
	}
	return chunks, nil
}
```

---

### Template 4 — Qdrant Vector Store + Payload Filtering (Python)

```python
# internal/search/qdrant_store.py
from qdrant_client import QdrantClient
from qdrant_client.models import (
    Distance, VectorParams, PointStruct,
    Filter, FieldCondition, MatchValue, Range,
    SearchRequest, NamedVector,
)
import uuid

client = QdrantClient(host="qdrant", port=6333)

COLLECTION = "knowledge-base"

def create_collection():
    """Create collection with HNSW config. Run once."""
    client.recreate_collection(
        collection_name=COLLECTION,
        vectors_config=VectorParams(
            size=1536,              # embedding dimension
            distance=Distance.COSINE,
            hnsw_config={"m": 16, "ef_construct": 100},
            on_disk=True,           # vectors stored on disk, not all in RAM
        ),
        optimizers_config={"memmap_threshold": 20_000},  # mmap for large collections
        quantization_config={       # scalar quantization: 4× memory reduction (minor recall loss)
            "scalar": {"type": "int8", "quantile": 0.99, "always_ram": True}
        },
    )
    # Create payload index for fast pre-filtering
    client.create_payload_index(COLLECTION, "tenant_id",  "keyword")
    client.create_payload_index(COLLECTION, "category",   "keyword")
    client.create_payload_index(COLLECTION, "created_at", "float")


def upsert_chunks(chunks: list[dict], embeddings: list[list[float]]):
    """Upsert document chunks with embeddings and metadata payload."""
    points = [
        PointStruct(
            id=str(uuid.uuid4()),
            vector=embedding,
            payload={
                "chunk_id":    chunk["id"],
                "document_id": chunk["document_id"],
                "content":     chunk["content"],
                "tenant_id":   chunk["tenant_id"],
                "category":    chunk["category"],
                "created_at":  chunk["created_at"].timestamp(),
            },
        )
        for chunk, embedding in zip(chunks, embeddings)
    ]
    client.upsert(collection_name=COLLECTION, points=points)


def search_similar(
    query_vector: list[float],
    tenant_id: str,
    category: str | None = None,
    top_k: int = 5,
    score_threshold: float = 0.70,
) -> list[dict]:
    """ANN search with payload pre-filter — filter runs inside the index."""
    conditions = [FieldCondition(key="tenant_id", match=MatchValue(value=tenant_id))]
    if category:
        conditions.append(FieldCondition(key="category", match=MatchValue(value=category)))

    results = client.search(
        collection_name=COLLECTION,
        query_vector=query_vector,
        query_filter=Filter(must=conditions),   # applied INSIDE HNSW — no post-filter overhead
        limit=top_k,
        score_threshold=score_threshold,        # discard results below similarity threshold
        with_payload=True,
        search_params={"hnsw_ef": 128},         # query-time recall parameter
    )

    return [
        {
            "id":       r.id,
            "score":    r.score,
            "content":  r.payload["content"],
            "document": r.payload["document_id"],
        }
        for r in results
    ]
```

---

### Template 5 — RAG Pipeline (Python + Claude API)

```python
# internal/rag/pipeline.py
import anthropic
from .qdrant_store import search_similar
from .embedder import embed_text   # wraps OpenAI / local model

client = anthropic.Anthropic()

SYSTEM_PROMPT = """You are a helpful assistant that answers questions based only
on the provided context. If the context does not contain enough information to
answer the question, say so clearly. Always cite which source you used."""

def answer_question(
    question: str,
    tenant_id: str,
    category: str | None = None,
    top_k: int = 5,
) -> dict:
    # Step 1: embed the question
    query_vector = embed_text(question)

    # Step 2: retrieve relevant chunks
    chunks = search_similar(
        query_vector=query_vector,
        tenant_id=tenant_id,
        category=category,
        top_k=top_k,
        score_threshold=0.65,
    )

    if not chunks:
        return {
            "answer": "I couldn't find relevant information to answer your question.",
            "sources": [],
            "chunks_used": 0,
        }

    # Step 3: build context block with citations
    context_blocks = []
    for i, chunk in enumerate(chunks, 1):
        context_blocks.append(
            f"[Source {i}] (similarity: {chunk['score']:.2f})\n{chunk['content']}"
        )
    context = "\n\n---\n\n".join(context_blocks)

    # Step 4: generate answer with Claude
    response = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=1024,
        system=SYSTEM_PROMPT,
        messages=[
            {
                "role": "user",
                "content": f"Context:\n{context}\n\nQuestion: {question}",
            }
        ],
    )

    return {
        "answer":      response.content[0].text,
        "sources":     [c["document"] for c in chunks],
        "chunks_used": len(chunks),
        "usage":       response.usage.model_dump(),
    }


def chunk_document(text: str, chunk_size: int = 500, overlap: int = 50) -> list[str]:
    """Split document into overlapping chunks at sentence boundaries."""
    import re
    sentences = re.split(r'(?<=[.!?])\s+', text)
    chunks, current, current_len = [], [], 0

    for sentence in sentences:
        words = len(sentence.split())
        if current_len + words > chunk_size and current:
            chunks.append(" ".join(current))
            # Keep overlap sentences
            overlap_words = 0
            overlap_sents = []
            for s in reversed(current):
                if overlap_words >= overlap:
                    break
                overlap_sents.insert(0, s)
                overlap_words += len(s.split())
            current = overlap_sents
            current_len = overlap_words
        current.append(sentence)
        current_len += words

    if current:
        chunks.append(" ".join(current))
    return chunks
```

---

### Template 6 — Elasticsearch Aggregations + function_score (Go)

```go
// internal/search/aggregations.go
package search

import (
	"context"
	"github.com/elastic/go-elasticsearch/v8"
	"github.com/elastic/go-elasticsearch/v8/typedapi/types"
)

// PaymentFacets returns aggregated facets for the search UI sidebar.
func PaymentFacets(ctx context.Context, es *elasticsearch.TypedClient, tenantID string) (map[string]any, error) {
	resp, err := es.Search().
		Index("payments-search").
		Request(&types.SearchRequest{
			Size: intPtr(0), // no hits — aggregations only
			Query: &types.Query{
				Term: map[string]types.TermQuery{
					"merchant_id": {Value: tenantID},
				},
			},
			Aggregations: map[string]types.Aggregations{
				"by_status": {
					Terms: &types.TermsAggregation{
						Field: strPtr("status"),
						Size:  intPtr(10),
					},
				},
				"by_currency": {
					Terms: &types.TermsAggregation{
						Field: strPtr("currency"),
						Size:  intPtr(20),
					},
				},
				"amount_stats": {
					Stats: &types.StatsAggregation{
						Field: strPtr("amount"),
					},
				},
				"over_time": {
					DateHistogram: &types.DateHistogramAggregation{
						Field:            strPtr("created_at"),
						CalendarInterval: &[]types.CalendarInterval{types.CalendarintervalDay}[0],
						MinDocCount:      intPtr(0),
					},
				},
			},
		}).
		Do(ctx)
	if err != nil {
		return nil, err
	}

	return resp.Aggregations, nil
}

// SearchWithBoost applies function_score to boost recent and high-value payments.
func SearchWithBoost(ctx context.Context, es *elasticsearch.TypedClient, query string) error {
	// function_score: base query score × recency decay × amount boost
	body := map[string]any{
		"query": map[string]any{
			"function_score": map[string]any{
				"query": map[string]any{
					"match": map[string]any{"reference": query},
				},
				"functions": []map[string]any{
					{
						// Decay: 50% score reduction for payments older than 30 days
						"gauss": map[string]any{
							"created_at": map[string]any{
								"origin": "now",
								"scale":  "30d",
								"decay":  0.5,
							},
						},
					},
					{
						// Boost payments over 10,000 by their log amount
						"filter": map[string]any{"range": map[string]any{"amount": map[string]any{"gte": 10000}}},
						"script_score": map[string]any{
							"script": map[string]any{
								"source": "Math.log(1 + doc['amount'].value)",
							},
						},
					},
				},
				"score_mode":  "sum",  // sum all function scores
				"boost_mode":  "multiply", // multiply with base query score
			},
		},
	}
	_ = body
	// Execute with es.Search() typed API or raw JSON body
	return nil
}

func intPtr(i int)    *int    { return &i }
func strPtr(s string) *string { return &s }
```

---

## Decision Matrix

| Scenario | Recommendation | Rationale |
|---|---|---|
| Keyword search on structured records (payments, orders) | Elasticsearch with `bool` query | Full-text + facets + aggregations in one query |
| Semantic search on documents / Q&A | pgvector (< 1M docs) or Qdrant (> 1M) | Embedding-based retrieval; keyword-agnostic |
| Product search (exact + fuzzy + filters) | Elasticsearch with `bool must` + `filter` | Handles synonym expansion, typos (`fuzziness`), facet counts |
| LLM Q&A with private knowledge base | RAG: Qdrant/pgvector retrieval + Claude API | Reduces hallucination; keeps context current without fine-tuning |
| Hybrid search (best of both) | RRF over BM25 hits + vector hits | Higher recall than either alone; no score normalisation needed |
| Existing PostgreSQL, < 1M embeddings | pgvector | No new infrastructure; HNSW fast enough at this scale |
| > 5M embeddings, sub-5 ms latency | Qdrant | Dedicated HNSW with on-disk vectors + scalar quantisation |
| Autocomplete / suggest | Elasticsearch `edge_ngram` analyzer | Prefix-indexed; very fast; supports scoring by popularity |
| Log / event search (time-series) | Elasticsearch with date histogram + BRIN-like time-based shards | Designed for append-only time-series; ILM for hot/warm/cold |
| Multi-modal search (text + image) | Qdrant with named vectors | Each modality has its own named vector; combined scoring |

---

## Proficiency Levels

### Level 1 — Aware
- Understands the difference between keyword search (inverted index) and semantic search (vector similarity)
- Can describe what an embedding is and why "payment failed" and "transaction error" are nearby in vector space
- Knows what RAG stands for and why it reduces hallucination
- Can run a basic Elasticsearch `match` query

### Level 2 — Practitioner
- Writes Elasticsearch index mappings with explicit field types and custom analyzers
- Constructs `bool` queries with `must`, `filter`, `should`, `must_not` clauses
- Implements pgvector HNSW index and nearest-neighbour SQL query with cosine distance
- Builds a basic RAG pipeline: embed → retrieve → prompt → generate
- Writes Elasticsearch `terms` and `date_histogram` aggregations for faceted search UI

### Level 3 — Advanced
- Designs shard strategy for an Elasticsearch index based on data size and query pattern
- Implements hybrid search with Reciprocal Rank Fusion across BM25 and vector results
- Configures Qdrant collection with payload indexes, scalar quantization, and on-disk vectors
- Tunes HNSW parameters (`m`, `ef_construction`, `ef_search`) with recall benchmarks
- Implements `function_score` for business-rule boosting (recency decay, popularity)
- Monitors Elasticsearch: shard health, indexing rate, query latency percentiles, JVM heap

### Level 4 — Expert
- Designs multi-tenant search infrastructure: index-per-tenant vs filtered single index (trade-offs in isolation, resource usage, reindexing cost)
- Implements ILM (Index Lifecycle Management) for time-series data: hot → warm → cold → delete policy
- Tunes embedding pipeline: chunking strategy, overlap, embedding model selection, batch inference
- Evaluates retrieval quality: NDCG, MRR, recall@K against human-labelled ground truth; A/B tests retrieval strategies
- Operates Elasticsearch cluster: rolling upgrades, cross-cluster replication for DR, snapshot/restore strategy

---

## AI Prompts

**Design an Elasticsearch index for a domain**
```
Design an Elasticsearch index mapping for [domain/entity] with these fields:
[list fields and their types]

Include:
1. Explicit mapping (dynamic: strict) with correct types for each field
2. Custom analyzer for full-text fields (lowercase, stemming, synonyms for [domain terms])
3. Edge-ngram analyzer for autocomplete on [field]
4. keyword subfield on text fields needed for aggregations
5. Index settings: shard count for [N GB] expected size, refresh_interval
6. Sample bool query covering: full-text search + keyword filter + date range + facets
```

**Build a RAG pipeline**
```
Build a RAG pipeline in Python for answering questions from [domain] documents:
1. Chunking: split documents at [sentence/paragraph] boundaries with [N] word overlap
2. Embedding: use [OpenAI text-embedding-3-small / local model]
3. Vector store: [pgvector / Qdrant] — configure index for [N] expected documents
4. Retrieval: top-[K] chunks with similarity threshold [X], filtered by tenant_id
5. Generation: Claude claude-sonnet-4-6 with system prompt instructing citation
6. Evaluation: measure retrieval recall@5 against [N] test questions with known answers

Include: chunking function, upsert function, retrieval function, and the full RAG query function.
```

**Implement hybrid search**
```
Implement hybrid search combining Elasticsearch BM25 and pgvector/Qdrant ANN using
Reciprocal Rank Fusion (RRF) in [Go/Python/TypeScript].

Steps:
1. Run BM25 query → get top-100 hits with ranks
2. Run ANN query → get top-100 hits with ranks
3. Compute RRF score = Σ 1/(60 + rank_i) for each document
4. Return top-K by RRF score with source content

Show how to run steps 1 and 2 in parallel, and how to merge results.
```

**Tune Elasticsearch for performance**
```
Review this Elasticsearch query and index mapping for performance issues:
[paste query + mapping]

Check for:
1. Filters that should be in filter context (not must — no scoring needed)
2. Missing keyword subfields on fields used in aggregations
3. Wildcard/leading-wildcard queries (very slow)
4. nested query performance (consider denormalisation)
5. Sort on un-indexed or text fields
6. Missing shard routing for tenant-scoped queries

Provide fixed query + mapping and explain each change.
```

---

## References

- **Elasticsearch documentation** — `elastic.co/guide` — query DSL, mappings, aggregations, ILM
- **`go-elasticsearch/v8`** — `github.com/elastic/go-elasticsearch` — official Go typed client
- **pgvector** — `github.com/pgvector/pgvector` — PostgreSQL vector extension; HNSW and IVF-Flat indexes
- **pgvector-go** — `github.com/pgvector/pgvector-go` — Go pgvector type for pgx/sqlx
- **Qdrant documentation** — `qdrant.tech/documentation` — collections, payload indexes, quantization, filtering
- **"Relevant Search"** — Turnbull & Berryman; Elasticsearch relevance tuning, BM25, function_score
- **RAG survey** — Lewis et al. (2020) "Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks"
- **HNSW paper** — Malkov & Yashunin (2018) "Efficient and Robust Approximate Nearest Neighbor Search"
- **Reciprocal Rank Fusion** — Cormack, Clarke, Buettcher (2009) — RRF algorithm for hybrid search
- **LlamaIndex** — `llamaindex.ai` — Python framework for RAG pipelines (chunking, retrieval, synthesis)
- **`anthropic` Python SDK** — `github.com/anthropics/anthropic-sdk-python` — for generation step in RAG
- **Elasticsearch ILM** — `elastic.co/guide/en/elasticsearch/reference/current/index-lifecycle-management.html`
