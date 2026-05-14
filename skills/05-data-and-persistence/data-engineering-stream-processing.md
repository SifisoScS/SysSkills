---
name: Data Engineering & Stream Processing
slug: data-engineering-stream-processing
category: 05-data-and-persistence
proficiency: advanced
description: >
  Production data engineering: Kafka topic design and consumer group semantics,
  Apache Flink stateful stream processing with event-time watermarks and windows,
  Spark Structured Streaming micro-batch with checkpointing, dbt incremental
  models and data quality tests, Apache Iceberg lakehouse format (time travel,
  schema evolution, partition evolution), CDC with Debezium, Avro/Protobuf
  schema registry, backpressure handling, and data mesh domain ownership
  principles. Covers the full pipeline from ingestion to serving layer.
tags:
  - kafka
  - apache-flink
  - spark-structured-streaming
  - dbt
  - apache-iceberg
  - debezium
  - schema-registry
  - avro
  - data-mesh
  - lakehouse
  - cdc
status: published
---

## Principles

### 1. Event Time Is the Ground Truth; Processing Time Is an Approximation
An event recorded at 14:03:02 happened at 14:03:02 regardless of when it
reaches the processing engine. Late-arriving events (network delays, mobile
offline sync) will arrive out of order. **Event-time processing** with
watermarks tolerates configurable lateness and produces correct aggregations.
Processing-time processing is simpler but produces wrong answers when
upstream latency changes — avoid it for anything beyond monitoring dashboards.

### 2. Exactly-Once Semantics Require Coordination at Both Ends
Kafka guarantees at-least-once delivery by default. Exactly-once end-to-end
requires: (a) idempotent producers (Kafka's `enable.idempotence=true`),
(b) transactional producers (`transactional.id`), and (c) an **idempotent
sink** (upsert by event ID, or a transactional sink like a database with
two-phase commit). Flink's checkpointing with Kafka source + sink achieves
exactly-once via distributed snapshots and Kafka transactions.

### 3. Schema Is a Contract Between Producers and Consumers
A producer that changes a JSON field name silently breaks every downstream
consumer. **Schema Registry** (Confluent, AWS Glue, Apicurio) enforces
forward/backward/full compatibility on every message publish. Avro and
Protobuf both support **schema evolution** (adding optional fields, renaming
with aliases) within the registered compatibility mode. Unregistered schema
changes are rejected at produce time — not discovered at consume time.

### 4. The Lakehouse Unifies Batch and Streaming on Open Table Formats
Apache Iceberg, Delta Lake, and Apache Hudi store data as Parquet files in
object storage with a **metadata layer** that provides ACID transactions,
time travel, schema evolution, and partition pruning — all features
previously requiring a proprietary data warehouse. Streaming jobs write
micro-batches; batch jobs run SQL; analytics engines (Spark, Trino,
ClickHouse) query the same files. This eliminates the Lambda architecture's
dual-codebase problem.

### 5. Data Mesh Shifts Ownership to Domain Teams
A central data team that owns all pipelines becomes a bottleneck as the
organisation grows. Data Mesh decentralises ownership: domain teams publish
**data products** (well-defined, SLO-backed datasets) that other teams
consume. Federated governance (global schema standards, quality contracts)
replaces central control. The platform team provides self-service
infrastructure (Kafka, Iceberg, a data catalogue) — not pipelines.

---

## Implementation Patterns

### Pattern A: Kafka Topic Design for High-Throughput Pipelines
Partitions are the unit of parallelism — a consumer group with N consumers
can process at most N partitions in parallel. Rule of thumb: target 1–10 MB/s
throughput per partition; over-partition rather than under-partition since
reducing partitions requires a full data migration. Use compacted topics for
CDC streams (retain only the latest value per key).

### Pattern B: Flink Keyed Streams + Managed State
Key the stream by entity ID before applying stateful operators (`reduce`,
`aggregate`, custom `KeyedProcessFunction`). Flink partitions state by key
and co-locates it with the processing thread — state access is local (no
network). Checkpointing snapshots state to S3/GCS on a configurable interval;
recovery replays from the latest checkpoint.

### Pattern C: dbt Incremental Models for Large Tables
Full-refresh models re-process all historical data on every run — expensive.
Incremental models process only new/changed rows since the last run using a
`max(updated_at)` watermark. Use `unique_key` for upsert semantics. Run
`--full-refresh` only when the model logic changes, not on every deploy.

### Pattern D: Iceberg Time Travel for Audit and Backfill
Every Iceberg table operation writes a new snapshot. `AS OF` queries select
data as it existed at any past timestamp or snapshot ID. Use time travel to
backfill a downstream table when an upstream pipeline bug is discovered and
corrected — replay from the snapshot before the bad data arrived.

### Pattern E: CDC → Kafka → Stream Processor → Serving Layer
Debezium monitors the database binlog and publishes row-level changes to
Kafka (one topic per table, key = primary key). A Flink or Spark job consumes
the CDC stream, applies transformations, and writes to the serving layer
(ClickHouse for real-time analytics, Iceberg for the data lake, Redis for
low-latency lookups).

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| Processing-time windows for business metrics | Metrics shift when Kafka consumer lag changes; dashboards show wrong numbers | Use event-time windows with watermarks; set allowed lateness based on p99 event delay |
| Single-partition Kafka topic | All consumers in a group process sequentially; no parallelism | Partition count ≥ expected consumer count; over-provision for future growth |
| Storing raw JSON in Kafka without schema registry | Schema drift discovered at consume time; no compatibility enforcement | Register Avro/Protobuf schema; configure BACKWARD_TRANSITIVE compatibility |
| dbt full-refresh on every run for large tables | Reprocesses terabytes daily; warehouse costs 10–100× incremental model | Switch to incremental with `unique_key`; full-refresh only on logic changes |
| Flink job with no checkpointing | Any failure restarts from the beginning; hours of reprocessing | Enable checkpointing every 1–5 minutes; use RocksDB state backend for large state |
| CDC source without `tombstone` handling | Deleted rows not propagated; downstream tables grow indefinitely | Handle Debezium `op: d` events in consumer; delete from serving layer |
| Lambda architecture (separate batch + streaming codebases) | Two codebases diverge; batch truth and streaming truth disagree | Replace with Kappa (streaming only) or Lakehouse with streaming ingest and batch reads |
| Uncapped consumer group lag | Consumer falls hours behind; catch-up causes downstream load spikes | Alert on consumer lag > N minutes; provision dedicated catch-up consumers |

---

## Code Templates

### Template 1 — Python: Flink Windowed Aggregation with Event-Time Watermarks
```python
# flink_order_metrics.py — PyFlink job: tumbling 1-minute windows on order events
# Requires: apache-flink[table] >= 1.18

from pyflink.datastream import StreamExecutionEnvironment, TimeCharacteristic
from pyflink.datastream.connectors.kafka import (
    KafkaSource, KafkaOffsetsInitializer
)
from pyflink.datastream.formats.avro import AvroRowDeserializationSchema
from pyflink.common import WatermarkStrategy, Duration, Row
from pyflink.common.typeinfo import Types
from pyflink.datastream.window import TumblingEventTimeWindows, Time
from pyflink.datastream.functions import (
    AggregateFunction, ProcessWindowFunction
)
import datetime

env = StreamExecutionEnvironment.get_execution_environment()
env.set_stream_time_characteristic(TimeCharacteristic.EventTime)
env.enable_checkpointing(60_000)           # checkpoint every 60 s
env.get_checkpoint_config().set_checkpoint_storage_uri("s3://my-bucket/flink-checkpoints/")

# Kafka source with schema registry Avro deserialisation
kafka_source = (
    KafkaSource.builder()
    .set_bootstrap_servers("kafka:9092")
    .set_topics("orders.events")
    .set_group_id("flink-order-metrics")
    .set_starting_offsets(KafkaOffsetsInitializer.committed_offsets())
    .set_value_only_deserializer(
        AvroRowDeserializationSchema.builder()
        .set_avro_schema(open("order_event.avsc").read())
        .build()
    )
    .build()
)

# Watermark strategy: allow up to 10 s of out-of-order events
watermark_strategy = (
    WatermarkStrategy
    .for_bounded_out_of_orderness(Duration.of_seconds(10))
    .with_timestamp_assigner(
        lambda event, _: int(event["event_timestamp_ms"])  # event-time field
    )
)

class OrderAggregator(AggregateFunction):
    def create_accumulator(self):
        return {"count": 0, "revenue": 0.0, "errors": 0}

    def add(self, value: Row, acc: dict):
        acc["count"] += 1
        acc["revenue"] += float(value["total_amount"])
        if value["status"] == "FAILED":
            acc["errors"] += 1
        return acc

    def get_result(self, acc: dict):
        return acc

    def merge(self, a: dict, b: dict):
        return {
            "count":   a["count"]   + b["count"],
            "revenue": a["revenue"] + b["revenue"],
            "errors":  a["errors"]  + b["errors"],
        }

class WindowResultEmitter(ProcessWindowFunction):
    def process(self, key, ctx, elements, out):
        agg = next(iter(elements))
        window_start = datetime.datetime.utcfromtimestamp(
            ctx.window().start / 1000
        ).isoformat()
        out.collect(Row(
            merchant_id=key,
            window_start=window_start,
            order_count=agg["count"],
            revenue=agg["revenue"],
            error_count=agg["errors"],
        ))

stream = (
    env.from_source(kafka_source, watermark_strategy, "Kafka Orders")
    .key_by(lambda e: e["merchant_id"])
    .window(TumblingEventTimeWindows.of(Time.minutes(1)))
    .aggregate(OrderAggregator(), WindowResultEmitter())
)

# Sink to ClickHouse via JDBC sink (not shown for brevity)
stream.print()
env.execute("Order Metrics — 1-minute tumbling windows")
```

### Template 2 — SQL + YAML: dbt Incremental Model with Data Quality Tests
```sql
-- models/marts/orders/fct_orders.sql
{{
  config(
    materialized = 'incremental',
    unique_key   = 'order_id',
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns',
    partition_by = {
      'field': 'order_date',
      'data_type': 'date',
      'granularity': 'day'
    },
    cluster_by = ['merchant_id', 'status'],
    tags = ['finance', 'daily']
  )
}}

with source as (
    select * from {{ source('raw', 'orders') }}
    {% if is_incremental() %}
    -- Only process rows updated since the last run.
    -- Uses the max updated_at already in the target table as the watermark.
    where updated_at > (select coalesce(max(updated_at), '1970-01-01') from {{ this }})
    {% endif %}
),

renamed as (
    select
        order_id,
        merchant_id,
        customer_id,
        cast(order_date as date)        as order_date,
        cast(total_amount_cents as numeric) / 100   as total_amount,
        lower(status)                   as status,
        created_at,
        updated_at,
        -- Derived field: is this a high-value order?
        total_amount_cents >= 10000     as is_high_value
    from source
    where order_id is not null          -- reject corrupt rows at model level
)

select * from renamed
```

```yaml
# models/marts/orders/schema.yml
version: 2

models:
  - name: fct_orders
    description: "Fact table: one row per order, incrementally updated"
    config:
      contract:
        enforced: true             # dbt contract: schema drift = CI failure

    columns:
      - name: order_id
        data_type: varchar
        description: "Surrogate key"
        tests:
          - unique
          - not_null

      - name: total_amount
        data_type: numeric
        tests:
          - not_null
          - dbt_utils.accepted_range:
              min_value: 0
              max_value: 1000000

      - name: status
        data_type: varchar
        tests:
          - not_null
          - accepted_values:
              values: ['pending', 'confirmed', 'shipped', 'cancelled', 'failed']

      - name: order_date
        data_type: date
        tests:
          - not_null
          - dbt_utils.not_future_date
```

### Template 3 — Python: Kafka Producer + Consumer with Avro Schema Registry
```python
# kafka_avro_producer.py
from confluent_kafka import Producer
from confluent_kafka.schema_registry import SchemaRegistryClient
from confluent_kafka.schema_registry.avro import AvroSerializer
from confluent_kafka.serialization import (
    StringSerializer, SerializationContext, MessageField
)
import json, time

SCHEMA_STR = """
{
  "type": "record",
  "name": "OrderEvent",
  "namespace": "com.company.orders",
  "fields": [
    {"name": "order_id",           "type": "string"},
    {"name": "merchant_id",        "type": "string"},
    {"name": "total_amount_cents", "type": "long"},
    {"name": "status",             "type": "string"},
    {"name": "event_timestamp_ms", "type": "long"},
    {"name": "schema_version",     "type": "int",    "default": 1}
  ]
}
"""

registry_client = SchemaRegistryClient({"url": "http://schema-registry:8081"})
avro_serializer = AvroSerializer(
    registry_client,
    SCHEMA_STR,
    # Compatibility: BACKWARD — consumers on v1 can read v2 messages
    # (new optional fields only; no field removals)
)
string_serializer = StringSerializer("utf_8")

producer = Producer({"bootstrap.servers": "kafka:9092"})

def produce_order_event(event: dict) -> None:
    producer.produce(
        topic="orders.events",
        key=string_serializer(event["order_id"]),
        value=avro_serializer(
            event,
            SerializationContext("orders.events", MessageField.VALUE)
        ),
        on_delivery=lambda err, msg: (
            print(f"Delivery error: {err}") if err else None
        ),
    )
    producer.poll(0)    # trigger delivery callbacks without blocking

# kafka_avro_consumer.py
from confluent_kafka import Consumer, KafkaException
from confluent_kafka.schema_registry.avro import AvroDeserializer

avro_deserializer = AvroDeserializer(registry_client)

consumer = Consumer({
    "bootstrap.servers": "kafka:9092",
    "group.id":          "order-processor-v1",
    "auto.offset.reset": "earliest",
    "enable.auto.commit": False,          # manual commit for exactly-once
})
consumer.subscribe(["orders.events"])

def consume_loop() -> None:
    try:
        while True:
            msg = consumer.poll(timeout=1.0)
            if msg is None:
                continue
            if msg.error():
                raise KafkaException(msg.error())

            event = avro_deserializer(
                msg.value(),
                SerializationContext(msg.topic(), MessageField.VALUE)
            )
            process_event(event)
            # Commit only after successful processing
            consumer.commit(message=msg, asynchronous=False)
    finally:
        consumer.close()

def process_event(event: dict) -> None:
    print(f"Processing order {event['order_id']} status={event['status']}")
```

### Template 4 — Python: Spark Structured Streaming with Iceberg Sink
```python
# spark_streaming_to_iceberg.py
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, from_json, to_timestamp, window
from pyspark.sql.types import (
    StructType, StructField, StringType, LongType, IntegerType
)

spark = (
    SparkSession.builder
    .appName("OrderMetrics-StreamingToIceberg")
    .config("spark.sql.extensions",
            "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
    .config("spark.sql.catalog.glue_catalog", "org.apache.iceberg.spark.SparkCatalog")
    .config("spark.sql.catalog.glue_catalog.warehouse", "s3://data-lake/warehouse/")
    .config("spark.sql.catalog.glue_catalog.catalog-impl",
            "org.apache.iceberg.aws.glue.GlueCatalog")
    .getOrCreate()
)

ORDER_SCHEMA = StructType([
    StructField("order_id",           StringType(), nullable=False),
    StructField("merchant_id",        StringType(), nullable=False),
    StructField("total_amount_cents", LongType(),   nullable=False),
    StructField("status",             StringType(), nullable=False),
    StructField("event_timestamp_ms", LongType(),   nullable=False),
])

# Read from Kafka — Spark manages consumer group offsets in checkpoints
raw_stream = (
    spark.readStream
    .format("kafka")
    .option("kafka.bootstrap.servers", "kafka:9092")
    .option("subscribe", "orders.events")
    .option("startingOffsets", "latest")
    .option("failOnDataLoss", "false")
    .load()
)

orders = (
    raw_stream
    .selectExpr("CAST(value AS STRING) as json_str", "timestamp as kafka_ts")
    .withColumn("data", from_json(col("json_str"), ORDER_SCHEMA))
    .select(
        col("data.order_id").alias("order_id"),
        col("data.merchant_id").alias("merchant_id"),
        (col("data.total_amount_cents") / 100).alias("total_amount"),
        col("data.status").alias("status"),
        to_timestamp(col("data.event_timestamp_ms") / 1000).alias("event_time"),
    )
    .filter(col("order_id").isNotNull())
)

# Write to Iceberg table with micro-batch checkpointing
query = (
    orders.writeStream
    .format("iceberg")
    .outputMode("append")
    .option("path", "glue_catalog.orders_db.fct_orders_streaming")
    .option("checkpointLocation", "s3://data-lake/checkpoints/fct_orders_streaming/")
    .option("fanout-enabled", "true")        # write to multiple partitions concurrently
    .trigger(processingTime="30 seconds")    # micro-batch every 30 s
    .start()
)
query.awaitTermination()
```

### Template 5 — SQL: Apache Iceberg Time Travel, Schema Evolution, Merge
```sql
-- Create an Iceberg table with partition evolution support
CREATE TABLE glue_catalog.orders_db.fct_orders (
    order_id        VARCHAR         NOT NULL,
    merchant_id     VARCHAR         NOT NULL,
    total_amount    DECIMAL(12,2)   NOT NULL,
    status          VARCHAR         NOT NULL,
    event_time      TIMESTAMP       NOT NULL,
    processed_at    TIMESTAMP       NOT NULL DEFAULT NOW()
)
USING iceberg
PARTITIONED BY (days(event_time), merchant_id)
TBLPROPERTIES (
    'write.target-file-size-bytes' = '134217728',   -- 128 MiB target file size
    'write.merge.mode'             = 'merge-on-read',
    'history.expire.min-snapshots-to-keep' = '10'
);

-- ── TIME TRAVEL ─────────────────────────────────────────────────────────────
-- Query data as it existed at a past timestamp (audit, backfill diagnosis)
SELECT * FROM glue_catalog.orders_db.fct_orders
TIMESTAMP AS OF '2026-05-01 00:00:00';

-- Query using a specific snapshot ID
SELECT * FROM glue_catalog.orders_db.fct_orders VERSION AS OF 5432109876543;

-- List all snapshots (snapshot_id, committed_at, operation)
SELECT snapshot_id, committed_at, operation, summary
FROM glue_catalog.orders_db.fct_orders.snapshots
ORDER BY committed_at DESC LIMIT 20;

-- ── SCHEMA EVOLUTION ────────────────────────────────────────────────────────
-- Add a nullable column — backward compatible; existing data reads NULL
ALTER TABLE glue_catalog.orders_db.fct_orders
ADD COLUMN refund_amount DECIMAL(12,2);

-- Rename a column without rewriting data (metadata-only operation)
ALTER TABLE glue_catalog.orders_db.fct_orders
RENAME COLUMN merchant_id TO seller_id;

-- ── PARTITION EVOLUTION ─────────────────────────────────────────────────────
-- Switch from daily to hourly partitioning without rewriting historical data
ALTER TABLE glue_catalog.orders_db.fct_orders
ADD PARTITION FIELD hours(event_time);
ALTER TABLE glue_catalog.orders_db.fct_orders
DROP PARTITION FIELD days(event_time);

-- ── MERGE (UPSERT) — CDC pattern ────────────────────────────────────────────
MERGE INTO glue_catalog.orders_db.fct_orders t
USING (
    SELECT order_id, merchant_id, total_amount, status, event_time,
           NOW() AS processed_at
    FROM staging.orders_cdc_batch
) s ON t.order_id = s.order_id
WHEN MATCHED AND s.status = 'DELETED' THEN DELETE
WHEN MATCHED THEN UPDATE SET
    t.status       = s.status,
    t.total_amount = s.total_amount,
    t.processed_at = s.processed_at
WHEN NOT MATCHED THEN INSERT *;

-- ── EXPIRE SNAPSHOTS (storage management) ───────────────────────────────────
CALL glue_catalog.system.expire_snapshots(
    table => 'orders_db.fct_orders',
    older_than => TIMESTAMP '2026-04-01 00:00:00',
    retain_last => 10
);
```

### Template 6 — Go: CDC Stream Processor — Debezium → Kafka → ClickHouse
```go
// cdc_processor/main.go — consume Debezium order CDC events and upsert to ClickHouse
package main

import (
    "context"
    "database/sql"
    "encoding/json"
    "log"
    "os"
    "os/signal"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
    _ "github.com/ClickHouse/clickhouse-go/v2"
)

// Debezium change event envelope (simplified)
type DebeziumEvent struct {
    Op     string          `json:"op"`    // 'c'=create, 'u'=update, 'd'=delete, 'r'=read(snapshot)
    Before json.RawMessage `json:"before"`
    After  json.RawMessage `json:"after"`
}

type Order struct {
    OrderID     string  `json:"order_id"`
    MerchantID  string  `json:"merchant_id"`
    TotalCents  int64   `json:"total_amount_cents"`
    Status      string  `json:"status"`
    UpdatedAtMs int64   `json:"updated_at_ms"`
}

func main() {
    ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
    defer cancel()

    consumer, err := kafka.NewConsumer(&kafka.ConfigMap{
        "bootstrap.servers":  "kafka:9092",
        "group.id":           "cdc-clickhouse-sink",
        "auto.offset.reset":  "earliest",
        "enable.auto.commit": false,
    })
    if err != nil {
        log.Fatal(err)
    }
    defer consumer.Close()
    consumer.Subscribe("dbserver1.public.orders", nil)

    ch, err := sql.Open("clickhouse", "clickhouse://clickhouse:9000/analytics")
    if err != nil {
        log.Fatal(err)
    }
    defer ch.Close()

    // ClickHouse ReplacingMergeTree for CDC upserts
    // Table DDL (run once):
    // CREATE TABLE orders ON CLUSTER '{cluster}' (
    //   order_id     String,  merchant_id String,
    //   total_amount Float64, status String,
    //   updated_at   DateTime64(3),
    //   _deleted     UInt8 DEFAULT 0          -- tombstone flag
    // ) ENGINE = ReplacingMergeTree(updated_at)
    // ORDER BY (merchant_id, order_id);

    batch := make([]Order, 0, 500)
    deletedIDs := make([]string, 0, 100)

    for {
        select {
        case <-ctx.Done():
            flushBatch(ch, batch, deletedIDs)
            return
        default:
        }

        msg, err := consumer.ReadMessage(100)
        if err != nil {
            if err.(kafka.Error).IsTimeout() {
                if len(batch) > 0 {
                    flushBatch(ch, batch, deletedIDs)
                    batch, deletedIDs = batch[:0], deletedIDs[:0]
                    consumer.Commit()
                }
                continue
            }
            log.Printf("consumer error: %v", err)
            continue
        }

        var event DebeziumEvent
        if err := json.Unmarshal(msg.Value, &event); err != nil {
            log.Printf("unmarshal error: %v", err)
            continue
        }

        switch event.Op {
        case "c", "u", "r":
            var o Order
            json.Unmarshal(event.After, &o)
            batch = append(batch, o)
        case "d":
            var o Order
            json.Unmarshal(event.Before, &o)
            deletedIDs = append(deletedIDs, o.OrderID)
        }

        if len(batch)+len(deletedIDs) >= 500 {
            flushBatch(ch, batch, deletedIDs)
            batch, deletedIDs = batch[:0], deletedIDs[:0]
            consumer.Commit()
        }
    }
}

func flushBatch(db *sql.DB, orders []Order, deletedIDs []string) {
    if len(orders) > 0 {
        tx, _ := db.Begin()
        stmt, _ := tx.Prepare(`
            INSERT INTO analytics.orders
            (order_id, merchant_id, total_amount, status, updated_at, _deleted)
            VALUES (?, ?, ?, ?, ?, 0)`)
        for _, o := range orders {
            stmt.Exec(o.OrderID, o.MerchantID,
                float64(o.TotalCents)/100, o.Status, o.UpdatedAtMs/1000)
        }
        stmt.Close()
        tx.Commit()
    }
    if len(deletedIDs) > 0 {
        // Insert tombstone row — ReplacingMergeTree will merge away old version
        tx, _ := db.Begin()
        stmt, _ := tx.Prepare(`
            INSERT INTO analytics.orders (order_id, _deleted) VALUES (?, 1)`)
        for _, id := range deletedIDs {
            stmt.Exec(id)
        }
        stmt.Close()
        tx.Commit()
    }
}
```

---

## Decision Matrix

| Scenario | Tool / Pattern | Key Config |
|---|---|---|
| Sub-second real-time aggregations (fraud detection, live dashboards) | Apache Flink with event-time windows | Checkpointing every 60 s; RocksDB state backend for large keyed state |
| Micro-batch ETL (< 30 s latency acceptable) | Spark Structured Streaming | 30 s trigger; Iceberg sink; checkpoint on S3 |
| Complex multi-table transformations, data quality, lineage | dbt (batch) + dbt Cloud Continuous Deployment | Incremental models; `dbt test` in CI; dbt docs for lineage |
| Database CDC to data lake | Debezium + Kafka + Iceberg MERGE | Avro schema registry; compacted CDC topic per table; daily MERGE job |
| Ad-hoc analytics on the data lake | Trino or Spark SQL over Iceberg | Partition pruning; ORC/Parquet columnar; Z-order clustering for common filters |
| Real-time OLAP (< 100 ms query latency) | ClickHouse with ReplacingMergeTree for CDC | Materialised views for pre-aggregation; sharding by merchant_id |
| Domain team publishing a data product | Data contract (AsyncAPI schema) + Iceberg table + SLO | Schema registry enforcement; dbt tests as quality gate; freshness SLO alert |
| Historical backfill after pipeline bug | Iceberg time travel + replay from snapshot | `TIMESTAMP AS OF` to identify good snapshot; Flink job replay from that watermark |

---

## Proficiency Levels

### Novice
- Understands batch vs streaming; knows what Kafka is conceptually
- Can read a dbt model; understands `source`, `ref`, and `materialised`
- Knows what a data warehouse vs a data lake is
- Runs `dbt run` and `dbt test` against a development database

### Intermediate
- Designs Kafka topic partitioning for target throughput
- Writes dbt incremental models with `unique_key` and `is_incremental()` guard
- Implements a Kafka consumer with manual commit and error handling
- Understands Flink's event-time vs processing-time and configures watermarks
- Queries Iceberg time-travel snapshots; performs `ALTER TABLE ADD COLUMN`
- Sets up Debezium connector config for a PostgreSQL source

### Advanced
- Designs end-to-end streaming pipelines with Flink: keyed state, windowing, checkpointing
- Implements exactly-once Kafka producers (idempotent + transactional)
- Registers Avro schemas with BACKWARD_TRANSITIVE compatibility; writes upcasters
- Builds CDC → Kafka → ClickHouse pipeline with tombstone handling
- Architects Iceberg lakehouse: partition strategy, file compaction schedule, snapshot expiry
- Defines data contracts with schema registry + dbt contract enforcement in CI

### Expert
- Designs multi-team data mesh: domain ownership, data product SLOs, federated governance
- Tunes Flink performance: operator chaining, async I/O for enrichment, network buffer tuning
- Implements custom Flink operators (ProcessFunction, CoProcessFunction) for complex event CEP
- Architects lambda-to-kappa migration on an existing dual-codebase pipeline estate
- Designs cross-region data replication strategy for Iceberg tables with conflict resolution
- Evaluates Apache Paimon, Apache Hudi, and Delta Lake vs Iceberg for specific workload profiles

---

## AI Prompts

```
You are an Apache Flink expert. I have an e-commerce platform with 50,000
order events per second. I need to detect fraud in real time: if the same
customer places more than 5 orders within 10 minutes, flag the 6th as
suspicious. Design the Flink job: what stream transformations, what keyed
state, what window type, and how do I handle late events arriving up to
2 minutes after their event time?
```

```
Acting as a data engineering architect: I have 15 microservices each with
their own PostgreSQL database. The data science team needs a unified data
lake for ML feature engineering. Design the CDC pipeline: Debezium
connector config for PostgreSQL, Kafka topic naming convention, schema
registry strategy, Iceberg table layout, and the dbt models to transform
raw CDC events into clean domain tables.
```

```
Explain the difference between Iceberg's copy-on-write and merge-on-read
write modes. For a table receiving 10,000 upserts per minute (CDC from a
payments database), which mode gives better write performance, which gives
better read performance, and how does compaction factor into the trade-off?
Show the Iceberg table property configuration for each mode.
```

```
I have a dbt project where the nightly full-refresh run on fct_orders takes
6 hours and costs $800 in BigQuery. Walk me through converting it to an
incremental model: the SQL changes needed, how to choose the right
incremental_strategy for BigQuery (insert_overwrite vs merge), how to
handle late-arriving source data, and what tests to add to verify the
incremental logic is correct.
```

```
Design a data contract framework for a Data Mesh organisation with 8 domain
teams. Each team publishes data products consumed by other teams. What does
a data contract contain (schema, SLOs, quality guarantees)? How is it
enforced technically (schema registry, dbt contract, CI pipeline checks)?
How do you handle breaking changes, and who has the authority to approve them?
```

---

## References

- **Narkhede, Shapira, Palino** — *Kafka: The Definitive Guide*, 2nd ed.
- **Flink docs** — https://flink.apache.org/docs/ — DataStream API, Table API, checkpointing
- **Apache Iceberg docs** — https://iceberg.apache.org/docs/ — time travel, evolution, Spark/Flink integration
- **dbt docs** — https://docs.getdbt.com — incremental models, contracts, tests
- **Debezium docs** — https://debezium.io/documentation/ — PostgreSQL, MySQL, MongoDB connectors
- **Confluent Schema Registry** — https://docs.confluent.io/platform/current/schema-registry/
- **ClickHouse docs** — https://clickhouse.com/docs — ReplacingMergeTree, AggregatingMergeTree, MV
- **Kleppmann, Martin** — *Designing Data-Intensive Applications*, Ch. 10–12 (Batch, Streams)
- **Data Mesh** — Zhamak Dehghani, *Data Mesh* (O'Reilly 2022)
- **Delta Lake docs** — https://docs.delta.io — alternative lakehouse format (Databricks ecosystem)
- **Apache Hudi docs** — https://hudi.apache.org/docs/ — near-real-time upserts on S3
- **SysSkills cross-reference** — `modern-database-selection-strategy`, `event-driven-architecture-cqrs`,
  `event-sourcing-deep-dive`, `observability-telemetry-strategy`, `cicd-gitops-strategy`
