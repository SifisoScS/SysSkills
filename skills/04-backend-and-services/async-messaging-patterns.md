---
name: Async Messaging Patterns
slug: async-messaging-patterns
category: 04-backend-and-services
proficiency: advanced
description: >
  Design reliable asynchronous messaging systems using the transactional
  outbox/inbox pattern, competing consumers, dead-letter queues, idempotency,
  and backpressure. Covers RabbitMQ exchange topology, SQS FIFO vs Standard,
  message deduplication, fan-out/fan-in, priority queues, and poison-message
  handling in Go, TypeScript, and Python. Connects to event-driven architecture
  and exactly-once Kafka semantics.
tags:
  - async-messaging
  - outbox-pattern
  - rabbitmq
  - sqs
  - dead-letter-queue
  - idempotency
  - competing-consumers
  - fan-out
  - backpressure
  - exactly-once
status: complete
---

## Principles

### Why Async Messaging
Synchronous request/response couples the caller to the availability, latency, and throughput of the callee. Async messaging decouples them:

```
Sync (tight coupling):          Async (decoupled):
                                      ┌──────────────┐
Caller ──req──▶ Service A  ◀──────── │   Message     │
               (must be up,           │   Broker      │
                must be fast,         └──────┬────────┘
                can't shed load)             │
                                     Service A consumes
                                     at its own pace
```

Use async messaging when:
- The caller does not need the result immediately (fire-and-forget, eventual consistency)
- The producer and consumer scale independently (burst absorption)
- Work must survive producer restarts (persistence)
- Multiple consumers need the same event (pub/sub, fan-out)

### Message Delivery Guarantees

| Guarantee | Meaning | Trade-off |
|---|---|---|
| **At-most-once** | Message may be lost; never duplicated | Fastest; no persistence required |
| **At-least-once** | Message delivered ≥1 time; may be duplicate | Most common; consumer must be idempotent |
| **Exactly-once** | Delivered precisely once | Expensive; requires broker + consumer coordination (Kafka transactions, SQS FIFO dedup) |

**At-least-once + idempotent consumer = effectively exactly-once** without the full transaction cost.

### Idempotency Key Pattern
Every message must carry a unique, stable identifier (`message_id`, `idempotency_key`). The consumer records processed IDs in a deduplication store (Redis, DB unique index). On duplicate delivery, the consumer detects the ID and skips processing without error.

```
Message arrives → check dedup store → ID seen? → ack, skip
                                    → ID new?  → process → record ID → ack
```

### The Outbox Pattern (Transactional Messaging)
The core problem: after updating the DB, the broker publish can fail, leaving the DB updated but no event emitted — a consistency gap.

```
WITHOUT outbox (broken):           WITH outbox (safe):
1. UPDATE accounts SET ...         1. BEGIN TRANSACTION
2. publish("payment.completed")        UPDATE accounts SET ...
   ← broker down = lost event          INSERT INTO outbox(event) VALUES(...)
                                    COMMIT
                                    2. Outbox relay reads outbox table
                                    3. relay publishes event to broker
                                    4. relay deletes row (or marks sent)
```

Both the DB update and the outbox insert are in the same ACID transaction — they either both commit or both roll back. The relay (a poller or CDC-based) publishes at-least-once; consumers handle duplicates via idempotency.

### Backpressure
When consumers are slower than producers, the queue grows unbounded. Strategies:
- **Rate limit producers** at the API layer (see api-security-rate-limiting skill)
- **Scale consumers** horizontally (competing consumers pattern)
- **Bounded queues** with overflow policy (drop oldest, drop newest, block producer)
- **KEDA** auto-scales consumer pods based on queue depth (see finops-cost-optimisation skill)

---

## Implementation Patterns

### 1. Competing Consumers
Multiple worker instances subscribe to the same queue. The broker delivers each message to exactly one consumer. This is the primary horizontal scaling pattern for queue workers. Requires idempotency because a crashed consumer may re-enqueue a message it had started processing.

### 2. Dead-Letter Queue (DLQ)
Messages that fail processing N times are moved to a DLQ. The DLQ is inspected by engineers; messages are replayed after fixing the bug or discarded if unrecoverable. Never silently drop failed messages.

### 3. Fan-Out (Pub/Sub)
One message published to a topic is delivered to all subscribers. In RabbitMQ: fanout exchange → N queues (one per consumer group). In SNS/SQS: SNS topic → N SQS queues. Each consumer group processes independently.

### 4. Priority Queue
Messages carry a priority value. The broker delivers higher-priority messages before lower-priority ones when both are enqueued. Use for mixed-urgency workloads (e.g., real-time alerts vs batch reports on the same worker).

### 5. Saga Choreography via Events
Each service emits domain events; downstream services react. No central orchestrator. The outbox pattern ensures events are reliably emitted. Compensating events undo partial work on failure (see saga-distributed-transactions skill for orchestration variant).

### 6. Inbox Pattern (Idempotent Consumer)
The consumer maintains an inbox table. Before processing, it inserts the `message_id` with a unique constraint. If the insert succeeds → process. If it fails (duplicate key) → skip. This is atomic with the business operation in the same DB transaction.

---

## Anti-Patterns

| Anti-Pattern | Why It Fails | Correction |
|---|---|---|
| **Publish after commit (two-phase)** | Broker failure after DB commit = lost event | Use transactional outbox — same transaction, relay publishes |
| **No idempotency** | At-least-once delivery causes duplicate effects (double charge, double email) | Idempotency key + dedup store checked before processing |
| **Infinite retry with no DLQ** | Poison messages spin forever, blocking the queue | DLQ after N failures; alert on DLQ depth |
| **Long processing inside consumer lock** | Message held unacked; broker timeout re-delivers to another consumer mid-processing | Ack immediately, store job state, process asynchronously — or extend ack timeout |
| **Message body contains all derived data** | Stale data; consumers get outdated snapshots | Emit IDs and minimal facts; consumers fetch current state (Event-Carried State Transfer only when appropriate) |
| **One queue for everything** | Mixed-urgency work; slow jobs block fast alerts | Separate queues by urgency/type; priority queues for mixed-urgency |
| **Consumer crashes without nack** | Message held until broker visibility timeout; late re-delivery | Graceful shutdown: drain in-flight messages on SIGTERM; set reasonable visibility timeout |
| **No schema on message payload** | Consumers break on producer schema change | Avro/Protobuf/JSON Schema with registry and compatibility checks |
| **Polling the DB instead of outbox relay** | Polling every 100ms = DB load at scale | CDC-based relay (Debezium) or efficient polling with SELECT FOR UPDATE SKIP LOCKED |
| **Giant messages (MB+) in broker** | Broker memory exhaustion; slow throughput | Claim-check pattern: store payload in S3/blob, send reference in message |

---

## Code Templates

### Template 1 — Transactional Outbox (Go + PostgreSQL + Relay)

```go
// internal/outbox/outbox.go — write side (same TX as business operation)
package outbox

import (
	"context"
	"encoding/json"
	"time"

	"github.com/google/uuid"
	"github.com/jmoiron/sqlx"
)

type Entry struct {
	ID          string    `db:"id"`
	Topic       string    `db:"topic"`
	Payload     []byte    `db:"payload"`
	IdempotencyKey string `db:"idempotency_key"`
	CreatedAt   time.Time `db:"created_at"`
	SentAt      *time.Time `db:"sent_at"`
}

// Append inserts an outbox entry within the caller's transaction.
// Call this inside the same tx.Begin() / tx.Commit() as the business operation.
func Append(ctx context.Context, tx *sqlx.Tx, topic string, event any) error {
	payload, err := json.Marshal(event)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO outbox (id, topic, payload, idempotency_key, created_at)
		VALUES ($1, $2, $3, $4, NOW())`,
		uuid.NewString(), topic, payload, uuid.NewString(),
	)
	return err
}
```

```go
// internal/outbox/relay.go — relay: polls outbox and publishes to broker
package outbox

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/jmoiron/sqlx"
	amqp "github.com/rabbitmq/amqp091-go"
)

type Relay struct {
	db      *sqlx.DB
	channel *amqp.Channel
	batch   int
	poll    time.Duration
}

func NewRelay(db *sqlx.DB, ch *amqp.Channel) *Relay {
	return &Relay{db: db, channel: ch, batch: 100, poll: 200 * time.Millisecond}
}

func (r *Relay) Run(ctx context.Context) {
	ticker := time.NewTicker(r.poll)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := r.flush(ctx); err != nil {
				slog.ErrorContext(ctx, "outbox relay error", "err", err)
			}
		}
	}
}

func (r *Relay) flush(ctx context.Context) error {
	// SELECT FOR UPDATE SKIP LOCKED: safe with multiple relay instances
	rows, err := r.db.QueryxContext(ctx, `
		SELECT id, topic, payload, idempotency_key
		FROM outbox
		WHERE sent_at IS NULL
		ORDER BY created_at
		LIMIT $1
		FOR UPDATE SKIP LOCKED`, r.batch)
	if err != nil {
		return err
	}
	defer rows.Close()

	var published []string
	for rows.Next() {
		var e Entry
		if err := rows.StructScan(&e); err != nil {
			return err
		}

		if err := r.channel.PublishWithContext(ctx, e.Topic, "", false, false, amqp.Publishing{
			MessageId:    e.ID,
			DeliveryMode: amqp.Persistent,
			ContentType:  "application/json",
			Headers:      amqp.Table{"idempotency-key": e.IdempotencyKey},
			Body:         e.Payload,
		}); err != nil {
			return err // stop batch on broker error; retry next poll
		}
		published = append(published, e.ID)
	}

	if len(published) == 0 {
		return nil
	}

	// Mark as sent
	query, args, _ := sqlx.In(`UPDATE outbox SET sent_at = NOW() WHERE id IN (?)`, published)
	query = r.db.Rebind(query)
	_, err = r.db.ExecContext(ctx, query, args...)
	return err
}
```

```sql
-- migrations/001_outbox.sql
CREATE TABLE outbox (
    id               UUID        PRIMARY KEY,
    topic            TEXT        NOT NULL,
    payload          JSONB       NOT NULL,
    idempotency_key  TEXT        NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sent_at          TIMESTAMPTZ
);

CREATE INDEX idx_outbox_unsent ON outbox (created_at) WHERE sent_at IS NULL;
```

---

### Template 2 — RabbitMQ Exchange Topology (Go)

```go
// internal/broker/topology.go — declare all exchanges and queues at startup
package broker

import (
	"fmt"
	amqp "github.com/rabbitmq/amqp091-go"
)

// DeclareTopology sets up the exchange and queue topology idempotently.
// Call this on startup from both producers and consumers (idempotent declarations).
func DeclareTopology(ch *amqp.Channel) error {
	// ── 1. Topic exchange for domain events ───────────────────────────────────
	if err := ch.ExchangeDeclare(
		"payments.events", // name
		"topic",           // type: route by routing key pattern (payments.#, *.completed)
		true,              // durable
		false,             // auto-delete
		false,             // internal
		false,             // no-wait
		nil,
	); err != nil {
		return fmt.Errorf("declare exchange: %w", err)
	}

	// ── 2. Dead-letter exchange ────────────────────────────────────────────────
	if err := ch.ExchangeDeclare("payments.dlx", "direct", true, false, false, false, nil); err != nil {
		return err
	}

	// ── 3. Queues with DLX configuration ──────────────────────────────────────
	queues := []struct {
		name       string
		routingKey string
		maxRetry   int
	}{
		{"fraud-scoring", "payments.initiated", 3},
		{"notification",  "payments.completed", 5},
		{"audit-log",     "payments.#", 10},         // all payment events
	}

	for _, q := range queues {
		dlqName := q.name + ".dlq"

		// Declare DLQ first (DLX routes here on rejection)
		if _, err := ch.QueueDeclare(dlqName, true, false, false, false, nil); err != nil {
			return fmt.Errorf("declare dlq %s: %w", dlqName, err)
		}
		if err := ch.QueueBind(dlqName, q.name, "payments.dlx", false, nil); err != nil {
			return err
		}

		// Declare main queue with DLX + message TTL for retry limit
		if _, err := ch.QueueDeclare(q.name, true, false, false, false, amqp.Table{
			"x-dead-letter-exchange":    "payments.dlx",
			"x-dead-letter-routing-key": q.name,
			"x-max-priority":            5, // enable priority (0–5)
		}); err != nil {
			return fmt.Errorf("declare queue %s: %w", q.name, err)
		}

		if err := ch.QueueBind(q.name, q.routingKey, "payments.events", false, nil); err != nil {
			return err
		}
	}

	return nil
}
```

```go
// internal/broker/consumer.go — competing consumer with idempotency + DLQ handling
package broker

import (
	"context"
	"encoding/json"
	"log/slog"

	amqp "github.com/rabbitmq/amqp091-go"
	"github.com/redis/go-redis/v9"
)

type Handler[T any] func(ctx context.Context, msg T) error

func ConsumeQueue[T any](
	ctx context.Context,
	ch *amqp.Channel,
	rdb *redis.Client,
	queueName string,
	concurrency int,
	handler Handler[T],
) error {
	// QoS: prefetch concurrency messages; don't overwhelm this consumer
	if err := ch.Qos(concurrency, 0, false); err != nil {
		return err
	}

	msgs, err := ch.ConsumeWithContext(ctx, queueName, "", false, false, false, false, nil)
	if err != nil {
		return err
	}

	sem := make(chan struct{}, concurrency)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case d, ok := <-msgs:
			if !ok {
				return nil // channel closed
			}
			sem <- struct{}{}
			go func(d amqp.Delivery) {
				defer func() { <-sem }()
				processMessage(ctx, rdb, d, handler)
			}(d)
		}
	}
}

func processMessage[T any](
	ctx context.Context,
	rdb *redis.Client,
	d amqp.Delivery,
	handler Handler[T],
) {
	msgID := d.MessageId
	if msgID == "" {
		msgID = d.CorrelationId
	}

	// Idempotency check via Redis SET NX
	if msgID != "" {
		key := "msgid:" + msgID
		set, _ := rdb.SetNX(ctx, key, 1, 0).Result() // no TTL = permanent dedup
		if !set {
			slog.InfoContext(ctx, "duplicate message skipped", "message_id", msgID)
			d.Ack(false)
			return
		}
	}

	var payload T
	if err := json.Unmarshal(d.Body, &payload); err != nil {
		slog.ErrorContext(ctx, "unmarshal failed", "err", err)
		d.Nack(false, false) // false = route to DLQ, don't requeue
		return
	}

	if err := handler(ctx, payload); err != nil {
		slog.ErrorContext(ctx, "handler failed", "queue", d.RoutingKey, "err", err)
		// Nack without requeue → message goes to DLX → DLQ
		d.Nack(false, false)
		return
	}

	d.Ack(false)
}
```

---

### Template 3 — AWS SQS FIFO vs Standard + DLQ (TypeScript)

```typescript
// src/messaging/sqsConsumer.ts
import {
  SQSClient,
  ReceiveMessageCommand,
  DeleteMessageCommand,
  ChangeMessageVisibilityCommand,
  Message,
} from "@aws-sdk/client-sqs";

const sqs = new SQSClient({ region: "eu-west-1" }); // uses IRSA — no static credentials

interface ConsumerOptions<T> {
  queueUrl: string;
  dlqUrl: string;
  maxRetries: number;
  visibilityTimeoutSecs: number;
  handler: (payload: T, messageId: string) => Promise<void>;
}

export async function runConsumer<T>(opts: ConsumerOptions<T>, signal: AbortSignal): Promise<void> {
  while (!signal.aborted) {
    const result = await sqs.send(new ReceiveMessageCommand({
      QueueUrl:              opts.queueUrl,
      MaxNumberOfMessages:   10,
      WaitTimeSeconds:       20,        // long-polling — avoids empty-receive charges
      VisibilityTimeout:     opts.visibilityTimeoutSecs,
      AttributeNames:        ["ApproximateReceiveCount"],
      MessageAttributeNames: ["All"],
    }));

    for (const msg of result.Messages ?? []) {
      await handleMessage(sqs, msg, opts);
    }
  }
}

async function handleMessage<T>(
  sqs: SQSClient,
  msg: Message,
  opts: ConsumerOptions<T>,
): Promise<void> {
  const receiveCount = parseInt(msg.Attributes?.ApproximateReceiveCount ?? "1", 10);
  const messageId    = msg.MessageId!;

  if (receiveCount > opts.maxRetries) {
    console.error({ messageId, receiveCount }, "Poison message — routing to DLQ");
    // SQS Standard: manually move; SQS FIFO: configure redrive policy on queue
    await sqs.send(new DeleteMessageCommand({
      QueueUrl:      opts.queueUrl,
      ReceiptHandle: msg.ReceiptHandle!,
    }));
    return;
  }

  let payload: T;
  try {
    payload = JSON.parse(msg.Body!) as T;
  } catch (e) {
    console.error({ messageId }, "Invalid JSON — discarding");
    await sqs.send(new DeleteMessageCommand({ QueueUrl: opts.queueUrl, ReceiptHandle: msg.ReceiptHandle! }));
    return;
  }

  try {
    await opts.handler(payload, messageId);
    // Delete on success (SQS does not auto-delete after processing)
    await sqs.send(new DeleteMessageCommand({
      QueueUrl:      opts.queueUrl,
      ReceiptHandle: msg.ReceiptHandle!,
    }));
  } catch (err) {
    console.error({ messageId, receiveCount, err }, "Handler failed — message will be retried");
    // Extend visibility so it isn't immediately re-delivered while we cool off
    const backoffSecs = Math.min(30 * receiveCount, 600); // exponential, cap 10 min
    await sqs.send(new ChangeMessageVisibilityCommand({
      QueueUrl:          opts.queueUrl,
      ReceiptHandle:     msg.ReceiptHandle!,
      VisibilityTimeout: backoffSecs,
    }));
  }
}
```

```typescript
// src/messaging/sqsProducer.ts
import {
  SQSClient,
  SendMessageCommand,
  SendMessageBatchCommand,
} from "@aws-sdk/client-sqs";
import { randomUUID } from "crypto";

const sqs = new SQSClient({ region: "eu-west-1" });

// SQS FIFO: MessageGroupId = ordering key; MessageDeduplicationId = idempotency
export async function publishFifo<T>(
  queueUrl: string,
  groupId: string,
  payload: T,
  deduplicationId?: string,
) {
  await sqs.send(new SendMessageCommand({
    QueueUrl:               queueUrl,
    MessageBody:            JSON.stringify(payload),
    MessageGroupId:         groupId,
    MessageDeduplicationId: deduplicationId ?? randomUUID(),
  }));
}

// Batch publish (up to 10 messages per batch — cheaper per-message cost)
export async function publishBatch<T>(
  queueUrl: string,
  payloads: T[],
) {
  const entries = payloads.map((p, i) => ({
    Id:          i.toString(),
    MessageBody: JSON.stringify(p),
  }));

  // SQS batch max is 10 messages
  for (let i = 0; i < entries.length; i += 10) {
    const batch = entries.slice(i, i + 10);
    const result = await sqs.send(new SendMessageBatchCommand({
      QueueUrl: queueUrl,
      Entries:  batch,
    }));
    if (result.Failed?.length) {
      throw new Error(`Batch publish failed for ${result.Failed.length} messages`);
    }
  }
}
```

---

### Template 4 — Fan-Out Pattern (SNS → Multiple SQS Queues, TypeScript)

```typescript
// infrastructure/messaging.tf equivalent in CDK (TypeScript)
// Pattern: SNS topic → N SQS subscriber queues, each with its own DLQ

import * as sns from "aws-cdk-lib/aws-sns";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as subscriptions from "aws-cdk-lib/aws-sns-subscriptions";
import { Duration, Stack } from "aws-cdk-lib";

export function createPaymentsFanOut(stack: Stack) {
  // Central topic — producers publish here once
  const topic = new sns.Topic(stack, "PaymentsTopic", {
    topicName: "payments-events",
    fifo: false,
  });

  // Each consumer group gets its own SQS queue + DLQ
  const consumers = ["fraud-scoring", "notification", "audit-log"];

  return consumers.map((name) => {
    const dlq = new sqs.Queue(stack, `${name}-dlq`, {
      queueName: `${name}-dlq`,
      retentionPeriod: Duration.days(14),
    });

    const queue = new sqs.Queue(stack, name, {
      queueName: name,
      visibilityTimeout: Duration.seconds(120),
      deadLetterQueue: { queue: dlq, maxReceiveCount: 3 },
      retentionPeriod: Duration.days(4),
    });

    // Subscribe the queue to the topic (fan-out delivery)
    topic.addSubscription(new subscriptions.SqsSubscription(queue, {
      filterPolicyWithMessageBody: name === "notification"
        ? {
            // Notification service only receives completed/failed events
            status: sns.FilterOrPolicy.filter(
              sns.SubscriptionFilter.stringFilter({
                allowlist: ["COMPLETED", "FAILED"],
              }),
            ),
          }
        : undefined,
    }));

    return { name, queue, dlq };
  });
}
```

---

### Template 5 — Inbox Pattern (Idempotent Consumer, Go + PostgreSQL)

```go
// internal/inbox/inbox.go — atomic idempotency within a DB transaction
package inbox

import (
	"context"
	"errors"
	"log/slog"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrDuplicate = errors.New("duplicate message")

// Process executes fn inside a transaction that atomically:
//  1. Inserts the messageID into the inbox table (unique constraint)
//  2. Runs the business logic fn
//
// If messageID already exists → ErrDuplicate (caller acks without processing).
func Process(ctx context.Context, pool *pgxpool.Pool, messageID string, fn func(pgx.Tx) error) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	_, err = tx.Exec(ctx,
		`INSERT INTO inbox (message_id, processed_at) VALUES ($1, NOW())`,
		messageID,
	)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			slog.InfoContext(ctx, "inbox: duplicate message", "message_id", messageID)
			return ErrDuplicate
		}
		return err
	}

	if err := fn(tx); err != nil {
		return err // tx rolled back; inbox insert rolled back too — message will be retried
	}

	return tx.Commit(ctx)
}
```

```sql
-- migrations/002_inbox.sql
CREATE TABLE inbox (
    message_id   TEXT        PRIMARY KEY,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Purge old entries after 7 days (prevent unbounded growth)
-- Run via pg_cron or a periodic Job
CREATE INDEX idx_inbox_processed_at ON inbox (processed_at);
```

```go
// Usage example: payment notification consumer
func (c *NotificationConsumer) HandlePaymentCompleted(
	ctx context.Context,
	msgID string,
	payload PaymentCompletedEvent,
) error {
	err := inbox.Process(ctx, c.pool, msgID, func(tx pgx.Tx) error {
		// All of this is atomic with the inbox insert
		_, err := tx.Exec(ctx,
			`INSERT INTO notifications (payment_id, user_id, sent_at) VALUES ($1, $2, NOW())`,
			payload.PaymentID, payload.UserID,
		)
		return err
	})
	if errors.Is(err, inbox.ErrDuplicate) {
		return nil // already processed; ack the broker message
	}
	return err
}
```

---

### Template 6 — Claim-Check Pattern + Priority Queue (Python)

```python
# messaging/claim_check.py — large payload handling via S3 + SQS pointer
import json
import uuid
import boto3
from dataclasses import dataclass

s3  = boto3.client("s3")
sqs = boto3.client("sqs", region_name="eu-west-1")

PAYLOAD_BUCKET = "org-message-payloads"
QUEUE_URL      = "https://sqs.eu-west-1.amazonaws.com/123456789/reports"

@dataclass
class ClaimCheckMessage:
    claim_id:   str
    bucket:     str
    key:        str
    content_type: str
    priority:   int = 3  # 0 = lowest, 9 = highest (RabbitMQ priority queue)


def publish_large_payload(payload: bytes, content_type: str, priority: int = 3) -> str:
    """Store payload in S3; publish pointer to SQS."""
    claim_id = str(uuid.uuid4())
    key = f"claims/{claim_id}"

    s3.put_object(
        Bucket      = PAYLOAD_BUCKET,
        Key         = key,
        Body        = payload,
        ContentType = content_type,
        # Auto-delete after 7 days
        Metadata    = {"ttl": "604800"},
    )

    msg = ClaimCheckMessage(claim_id=claim_id, bucket=PAYLOAD_BUCKET, key=key, content_type=content_type, priority=priority)
    sqs.send_message(
        QueueUrl    = QUEUE_URL,
        MessageBody = json.dumps(vars(msg)),
        MessageAttributes={
            "priority": {"StringValue": str(priority), "DataType": "Number"},
        },
    )
    return claim_id


def fetch_payload(msg: ClaimCheckMessage) -> bytes:
    """Retrieve payload from S3 and delete the claim."""
    response = s3.get_object(Bucket=msg.bucket, Key=msg.key)
    data = response["Body"].read()
    s3.delete_object(Bucket=msg.bucket, Key=msg.key)
    return data


# ── Priority queue consumer (RabbitMQ, Python pika) ───────────────────────────
import pika

def start_priority_consumer(queue: str, handler):
    """Consume from a RabbitMQ priority queue (x-max-priority declared at creation)."""
    conn   = pika.BlockingConnection(pika.ConnectionParameters("rabbitmq"))
    ch     = conn.channel()

    # Declare with priority support (must match producer declaration)
    ch.queue_declare(queue, durable=True, arguments={"x-max-priority": 10})
    ch.basic_qos(prefetch_count=5)

    def on_message(ch, method, properties, body):
        priority = properties.priority or 0
        try:
            payload = json.loads(body)
            handler(payload, priority=priority)
            ch.basic_ack(method.delivery_tag)
        except Exception as exc:
            print(f"Handler failed (priority={priority}): {exc}")
            # Nack without requeue → goes to DLX if configured
            ch.basic_nack(method.delivery_tag, requeue=False)

    ch.basic_consume(queue, on_message)
    ch.start_consuming()
```

---

## Decision Matrix

| Scenario | Recommendation | Rationale |
|---|---|---|
| Reliable event emission from a DB-backed service | Transactional outbox + relay | Atomicity between DB write and event; no dual-write failure |
| Multiple services need the same event | SNS fan-out → per-team SQS queues | Each consumer scales independently; filtered subscriptions |
| Strict ordering per entity (e.g., per user) | SQS FIFO with `MessageGroupId` = entity ID | Per-group FIFO ordering; exactly-once with content deduplication |
| High-throughput, ordering not required | SQS Standard or Kafka | Higher throughput; at-least-once delivery |
| Complex routing by event type | RabbitMQ topic exchange (`payments.#`, `*.completed`) | Flexible pattern routing without fan-out overhead |
| Consumer needs to be idempotent | Inbox pattern (DB unique constraint + same transaction) | Atomic idempotency; no separate cache needed |
| Message payload > 256 KB (SQS limit) | Claim-check: store in S3, send pointer | Avoids broker limits; payload stored durably |
| Mixed-urgency work (alerts + reports) | Priority queue (`x-max-priority`) | Alerts processed before reports without separate queues |
| Failed messages need human inspection | DLQ with monitoring alert on depth > 0 | Never silently drop; DLQ is an audit trail |
| Consumer scaling by queue depth | KEDA `ScaledObject` with SQS/Kafka trigger | Scales to zero off-hours; scales instantly on backlog |

---

## Proficiency Levels

### Level 1 — Aware
- Understands why async messaging decouples producers from consumers
- Knows at-most-once vs at-least-once vs exactly-once trade-offs
- Can describe the outbox pattern and why it solves dual-write inconsistency
- Understands what a dead-letter queue is and when to inspect it

### Level 2 — Practitioner
- Implements the transactional outbox (INSERT in same TX + relay poller with `SELECT FOR UPDATE SKIP LOCKED`)
- Writes a competing-consumer worker with idempotency key check in Redis
- Configures RabbitMQ topic exchange with DLX bindings or SQS queues with redrive policy
- Handles `SIGTERM` gracefully: stops accepting new messages, drains in-flight, closes connection
- Sets SQS `WaitTimeSeconds: 20` (long-polling) and `VisibilityTimeout` appropriate to processing time

### Level 3 — Advanced
- Designs fan-out topology for 5+ consumer teams with filtered SNS subscriptions
- Implements the inbox pattern (DB unique constraint + business logic in same transaction)
- Applies the claim-check pattern for payloads exceeding broker size limits
- Configures priority queues; separates urgency tiers without multiplying queue count unnecessarily
- Monitors queue health: DLQ depth alert, consumer lag alert, message age alert

### Level 4 — Expert
- Designs org-wide messaging strategy: broker selection (Kafka for log retention/replay, RabbitMQ for flexible routing, SQS for serverless), schema registry, versioning policy
- Implements saga choreography via events with compensating transactions and outbox for every step
- Operates CDC-based outbox relay (Debezium + Kafka Connect) for zero-polling latency
- Tunes RabbitMQ cluster: quorum queues, mirroring policy, connection management, flow control thresholds
- Handles exactly-once end-to-end with Kafka transactions + idempotent producers + transactional consumers

---

## AI Prompts

**Implement the transactional outbox pattern**
```
Implement the transactional outbox pattern for a [Go/TypeScript/Python] service
using [PostgreSQL/MySQL] that:
1. Appends an outbox entry inside the same DB transaction as the business operation
2. Has a relay that polls for unsent entries using SELECT FOR UPDATE SKIP LOCKED
3. Publishes to [RabbitMQ topic exchange / SNS / Kafka topic]
4. Marks entries as sent after successful publish
5. Handles relay restarts safely (idempotent publish with message_id)

Include: outbox table DDL, Append() function, Relay.Run() function, and
a purge job for old sent entries.
```

**Design a fan-out messaging topology**
```
Design a fan-out messaging topology where a [payment / order / user] service
emits events consumed by [N] downstream services:
[list consumer services and what events they care about]

Choose between: SNS+SQS fan-out, RabbitMQ topic exchange, or Kafka topic.
Justify the choice.
For each consumer: queue name, filter criteria, DLQ config, retry policy.
Include infrastructure-as-code (CDK / Terraform / RabbitMQ AMQP declarations).
```

**Implement idempotent message consumer**
```
Implement an idempotent consumer for [Go/TypeScript/Python] that:
- Checks a message_id dedup store before processing
- If duplicate: ack without processing
- If new: process atomically with the dedup record insertion (inbox pattern)
- Uses [Redis SET NX / PostgreSQL unique constraint] for dedup storage
- Handles the case where processing succeeds but ack fails (broker delivers again)

Show both the inbox table DDL and the handler wrapper function.
```

**Write a DLQ monitoring alert**
```
Write a Prometheus alerting rule (PrometheusRule CRD) and a Python/Go script
that:
1. Alerts when a DLQ has depth > 0 for more than 5 minutes (severity: warning)
2. Alerts when DLQ depth > 100 (severity: critical)
3. Exposes DLQ depth as a custom metric scraped from [RabbitMQ management API / SQS GetQueueAttributes]

Include: metric scraper, PrometheusRule YAML, and a Grafana panel JSON snippet
for DLQ depth over time.
```

---

## References

- **Enterprise Integration Patterns** — Hohpe & Woolf; canonical reference for messaging topologies, patterns, and anti-patterns
- **RabbitMQ documentation** — `rabbitmq.com/docs` — exchanges, queues, bindings, DLX, quorum queues
- **AWS SQS documentation** — FIFO vs Standard, visibility timeout, redrive policy, long polling
- **AWS SNS documentation** — fan-out, filter policies, message attributes
- **`rabbitmq/amqp091-go`** — `github.com/rabbitmq/amqp091-go` — Go AMQP 0-9-1 client
- **`@aws-sdk/client-sqs`** — AWS SDK v3 TypeScript SQS client
- **Outbox pattern** — `microservices.io/patterns/data/transactional-outbox.html` — canonical description
- **Claim-check pattern** — `enterpriseintegrationpatterns.com/patterns/messaging/StoreInLibrary.html`
- **KEDA SQS scaler** — `keda.sh/docs/scalers/aws-sqs` — auto-scale consumers on queue depth
- **Debezium** — `debezium.io` — CDC-based outbox relay (zero-polling latency alternative to poller)
- **`SELECT FOR UPDATE SKIP LOCKED`** — PostgreSQL docs — concurrent-safe queue processing from DB
