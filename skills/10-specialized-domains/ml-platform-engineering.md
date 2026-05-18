---
name: ML Platform Engineering
slug: ml-platform-engineering
category: 10-specialized-domains
proficiency: advanced
description: >
  Design and operate the infrastructure layer that enables teams to train,
  evaluate, deploy, and monitor ML models at scale. Covers feature stores,
  model registries, training pipelines with Kubeflow/Argo, model serving
  with Triton and vLLM, A/B testing for models, drift detection, and
  MLOps practices for production reliability.
tags:
  - mlops
  - ml-platform
  - feature-store
  - model-registry
  - kubeflow
  - model-serving
  - triton
  - vllm
  - drift-detection
  - a-b-testing
status: published
---

## Principles

### The ML Platform Problem
ML teams without a platform spend 80% of their time on infrastructure:
- "Where do I get the features I need, without data leakage?"
- "How do I train reproducibly across experiments?"
- "How do I deploy a model without writing a service from scratch?"
- "How do I know if my model is degrading in production?"

A platform answers these questions once, so ML engineers focus on models.

### The ML Lifecycle
```
Data → Feature Engineering → Training → Evaluation → Serving → Monitoring
  ↑                                                                  |
  └──────────────────── Feedback Loop ───────────────────────────────┘
```

Each stage has distinct platform needs:
| Stage | Platform Concern |
|-------|----------------|
| Feature engineering | Feature store (consistency between training and serving) |
| Training | Experiment tracking, reproducibility, GPU scheduling |
| Evaluation | Model registry, A/B test framework, offline metrics |
| Serving | Low-latency inference, batching, scaling, versioning |
| Monitoring | Data drift, model drift, prediction distribution shifts |

### Training-Serving Skew (The Biggest MLOps Bug)
The model performs well offline but degrades in production because:
- Training used features computed differently from serving
- Training data had different distributions than production traffic
- Preprocessing pipeline differs between training and serving

**Fix**: a feature store with a single feature definition used in both contexts. The same feature computation runs at training time (offline/batch) and serving time (online/real-time).

### The Four Key MLOps Maturity Levels
- **Level 0**: manual training, manual deploy, no monitoring — "script and pray"
- **Level 1**: automated pipelines, experiment tracking, manual deploy
- **Level 2**: automated retraining triggers, CI/CD for models, basic monitoring
- **Level 3**: continuous training, automated A/B testing, automated rollback, full observability

---

## Implementation Patterns

### Pattern 1 — Feature Store with Feast
```python
# feature_store/features.py — define features once, use everywhere

from datetime import timedelta
from feast import Entity, Feature, FeatureView, FileSource, ValueType
from feast.types import Float32, Int64, String

# ── Entity — the "join key" between feature tables and labels ─────────────────

customer = Entity(
    name="customer_id",
    value_type=ValueType.STRING,
    description="Customer identifier",
)

# ── Data source — could be S3 Parquet, BigQuery, Redshift, Kafka ──────────────

customer_stats_source = FileSource(
    path="s3://ml-features/customer_stats/",
    event_timestamp_column="event_timestamp",
    created_timestamp_column="created_timestamp",
)

# ── Feature view — logical grouping of features for an entity ────────────────

customer_transaction_features = FeatureView(
    name="customer_transaction_features",
    entities=["customer_id"],
    ttl=timedelta(days=7),  # features expire after 7 days
    features=[
        Feature(name="transaction_count_7d",     dtype=Float32),
        Feature(name="avg_transaction_value_7d", dtype=Float32),
        Feature(name="max_transaction_value_30d", dtype=Float32),
        Feature(name="days_since_last_transaction", dtype=Int64),
        Feature(name="preferred_currency",       dtype=String),
        Feature(name="fraud_score",              dtype=Float32),
    ],
    online=True,  # materialise to online store (Redis) for low-latency serving
    source=customer_stats_source,
)
```

```python
# ml/training/fraud_model_train.py — training uses offline feature retrieval

import feast
import pandas as pd
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import roc_auc_score
import mlflow
import mlflow.sklearn

def train_fraud_model(entity_df: pd.DataFrame) -> None:
    """
    entity_df: must contain customer_id and event_timestamp columns
    Feast handles point-in-time correct feature retrieval — prevents data leakage
    """
    store = feast.FeatureStore(repo_path="feature_store/")

    # Historical feature retrieval (point-in-time correct)
    training_df = store.get_historical_features(
        entity_df=entity_df,
        features=[
            "customer_transaction_features:transaction_count_7d",
            "customer_transaction_features:avg_transaction_value_7d",
            "customer_transaction_features:fraud_score",
            "customer_transaction_features:days_since_last_transaction",
        ],
    ).to_df()

    X = training_df[[
        "transaction_count_7d",
        "avg_transaction_value_7d",
        "fraud_score",
        "days_since_last_transaction",
    ]]
    y = entity_df["is_fraud"]  # labels from entity_df

    with mlflow.start_run():
        mlflow.set_tags({"feature_store": "feast", "model_type": "gbm"})
        mlflow.log_params({"n_estimators": 200, "max_depth": 5, "learning_rate": 0.05})

        model = GradientBoostingClassifier(
            n_estimators=200, max_depth=5, learning_rate=0.05
        )
        model.fit(X, y)

        auc = roc_auc_score(y, model.predict_proba(X)[:, 1])
        mlflow.log_metric("train_auc", auc)
        mlflow.sklearn.log_model(
            model,
            artifact_path="fraud_model",
            registered_model_name="fraud-detection",
        )
        print(f"Trained fraud model. AUC: {auc:.4f}")
```

```python
# ml/serving/fraud_scorer.py — serving uses the SAME feature definitions

import feast
import numpy as np

store = feast.FeatureStore(repo_path="feature_store/")

def score_transaction(customer_id: str, transaction_amount: float) -> float:
    """Returns fraud probability for an incoming transaction."""

    # Online feature lookup — microseconds, not milliseconds
    feature_vector = store.get_online_features(
        features=[
            "customer_transaction_features:transaction_count_7d",
            "customer_transaction_features:avg_transaction_value_7d",
            "customer_transaction_features:fraud_score",
            "customer_transaction_features:days_since_last_transaction",
        ],
        entity_rows=[{"customer_id": customer_id}],
    ).to_df()

    X = feature_vector[[
        "transaction_count_7d",
        "avg_transaction_value_7d",
        "fraud_score",
        "days_since_last_transaction",
    ]].fillna(0).values

    return float(model.predict_proba(X)[0, 1])
```

### Pattern 2 — Kubeflow Training Pipeline
```python
# pipelines/fraud_training_pipeline.py — Kubeflow Pipelines v2

from kfp import dsl
from kfp.dsl import Dataset, Model, Input, Output, Metrics, component

@component(
    base_image="python:3.11",
    packages_to_install=["feast", "pandas", "scikit-learn", "mlflow"],
)
def fetch_features(
    start_date: str,
    end_date: str,
    output_dataset: Output[Dataset],
):
    """Pull features from the feature store for the training window."""
    import feast
    import pandas as pd

    store = feast.FeatureStore(repo_path="/feast")
    entity_df = pd.read_parquet(f"s3://ml-data/entities/{start_date}_to_{end_date}.parquet")

    training_df = store.get_historical_features(
        entity_df=entity_df,
        features=[
            "customer_transaction_features:transaction_count_7d",
            "customer_transaction_features:avg_transaction_value_7d",
        ],
    ).to_df()

    training_df.to_parquet(output_dataset.path)


@component(
    base_image="python:3.11",
    packages_to_install=["scikit-learn", "mlflow", "pandas"],
)
def train_model(
    training_data: Input[Dataset],
    model_output: Output[Model],
    metrics_output: Output[Metrics],
    n_estimators: int = 200,
    max_depth: int = 5,
):
    """Train the fraud detection model."""
    import pandas as pd
    import mlflow
    from sklearn.ensemble import GradientBoostingClassifier
    from sklearn.model_selection import train_test_split
    from sklearn.metrics import roc_auc_score
    import pickle

    df = pd.read_parquet(training_data.path)
    X = df.drop(columns=["is_fraud", "customer_id", "event_timestamp"])
    y = df["is_fraud"]

    X_train, X_val, y_train, y_val = train_test_split(X, y, test_size=0.2, random_state=42)

    with mlflow.start_run():
        model = GradientBoostingClassifier(n_estimators=n_estimators, max_depth=max_depth)
        model.fit(X_train, y_train)

        auc = roc_auc_score(y_val, model.predict_proba(X_val)[:, 1])
        mlflow.log_metric("val_auc", auc)
        metrics_output.log_metric("val_auc", auc)

        with open(model_output.path, "wb") as f:
            pickle.dump(model, f)


@component(
    base_image="python:3.11",
    packages_to_install=["mlflow"],
)
def register_model(
    model: Input[Model],
    metrics: Input[Metrics],
    model_name: str,
    min_auc_threshold: float = 0.85,
) -> str:
    """Register model in MLflow registry if it meets the quality gate."""
    import mlflow
    import mlflow.sklearn
    import pickle

    auc = metrics.metadata["val_auc"]
    if auc < min_auc_threshold:
        raise ValueError(f"Model AUC {auc:.4f} below threshold {min_auc_threshold}")

    with open(model.path, "rb") as f:
        clf = pickle.load(f)

    with mlflow.start_run():
        result = mlflow.sklearn.log_model(
            clf,
            artifact_path="model",
            registered_model_name=model_name,
        )
        mlflow.register_model(result.model_uri, model_name)
    return result.run_id


@dsl.pipeline(name="fraud-detection-training")
def fraud_training_pipeline(
    start_date: str,
    end_date: str,
    model_name: str = "fraud-detection",
):
    fetch_task = fetch_features(start_date=start_date, end_date=end_date)
    train_task = train_model(training_data=fetch_task.outputs["output_dataset"])
    register_model(
        model=train_task.outputs["model_output"],
        metrics=train_task.outputs["metrics_output"],
        model_name=model_name,
    )
```

### Pattern 3 — Model Serving with BentoML + Kubernetes
```python
# services/fraud_scorer_service.py — BentoML service definition

import bentoml
import numpy as np
import feast
from bentoml.io import JSON
from pydantic import BaseModel

class ScoreRequest(BaseModel):
    customer_id: str
    transaction_amount: float
    merchant_category: str

class ScoreResponse(BaseModel):
    fraud_probability: float
    decision: str   # "allow", "review", "block"
    model_version: str

fraud_model_runner = bentoml.mlflow.get("fraud-detection:latest").to_runner()

svc = bentoml.Service("fraud-scorer", runners=[fraud_model_runner])

store = feast.FeatureStore(repo_path="/feast")

@svc.api(input=JSON(pydantic_model=ScoreRequest), output=JSON(pydantic_model=ScoreResponse))
async def score(req: ScoreRequest) -> ScoreResponse:
    # Fetch online features
    features = store.get_online_features(
        features=[
            "customer_transaction_features:transaction_count_7d",
            "customer_transaction_features:avg_transaction_value_7d",
            "customer_transaction_features:fraud_score",
        ],
        entity_rows=[{"customer_id": req.customer_id}],
    ).to_df()

    X = features[[
        "transaction_count_7d",
        "avg_transaction_value_7d",
        "fraud_score",
    ]].fillna(0).values

    # Async inference — doesn't block event loop
    prob = await fraud_model_runner.predict_proba.async_run(X)
    fraud_prob = float(prob[0, 1])

    decision = "allow"
    if fraud_prob > 0.7:
        decision = "block"
    elif fraud_prob > 0.4:
        decision = "review"

    return ScoreResponse(
        fraud_probability=fraud_prob,
        decision=decision,
        model_version=fraud_model_runner.latest_version,
    )
```

### Pattern 4 — Model Drift Detection (Evidently)
```python
# monitoring/drift_monitor.py — detect data and prediction drift

import pandas as pd
from evidently.report import Report
from evidently.metric_preset import DataDriftPreset, TargetDriftPreset, DataQualityPreset
from evidently.metrics import ColumnDriftMetric, DatasetDriftMetric
import mlflow

def run_drift_report(
    reference_df: pd.DataFrame,
    production_df: pd.DataFrame,
    output_path: str,
    model_name: str,
) -> dict:
    """
    reference_df: training data distribution (baseline)
    production_df: last 24h of production predictions + input features
    """

    report = Report(metrics=[
        DataDriftPreset(),           # feature-level drift
        TargetDriftPreset(),         # prediction/label distribution drift
        DataQualityPreset(),         # missing values, out-of-range values
        ColumnDriftMetric(column_name="transaction_count_7d"),
        ColumnDriftMetric(column_name="fraud_probability"),  # model output drift
    ])

    report.run(reference_data=reference_df, current_data=production_df)
    report.save_html(output_path)

    result = report.as_dict()
    drift_summary = {
        "dataset_drift_detected": result["metrics"][0]["result"]["dataset_drift"],
        "drifted_features": result["metrics"][0]["result"]["number_of_drifted_columns"],
        "prediction_drift": result["metrics"][1]["result"].get("drift_detected", False),
    }

    # Log drift metrics to MLflow for tracking over time
    with mlflow.start_run(run_name=f"drift-check-{model_name}"):
        mlflow.log_metric("drifted_features", drift_summary["drifted_features"])
        mlflow.log_metric("dataset_drift", int(drift_summary["dataset_drift_detected"]))
        mlflow.log_artifact(output_path, "drift_report")

    return drift_summary


def alert_on_drift(drift_summary: dict, threshold_drifted_features: int = 2) -> None:
    """Trigger an alert if drift exceeds threshold."""
    if drift_summary["dataset_drift_detected"]:
        raise ValueError(
            f"Data drift detected: {drift_summary['drifted_features']} features drifted. "
            f"Consider retraining."
        )
    if drift_summary["prediction_drift"]:
        raise ValueError("Prediction distribution drift detected. Investigate model performance.")
```

### Pattern 5 — A/B Testing for Models (Kubernetes Traffic Splitting)
```yaml
# kubernetes/fraud-model-ab-test.yaml — split traffic between model versions
# Uses Istio VirtualService for precise traffic control

apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: fraud-scorer-ab-test
  namespace: ml-serving
spec:
  hosts:
    - fraud-scorer.ml-serving.svc.cluster.local
  http:
    - route:
        - destination:
            host: fraud-scorer-v1   # current production model
            port:
              number: 3000
          weight: 80
        - destination:
            host: fraud-scorer-v2   # challenger model
            port:
              number: 3000
          weight: 20
      headers:
        response:
          set:
            X-Model-Version: "experiment-001"

---
# Prometheus recording rules for A/B test metrics
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: fraud-model-ab-metrics
  namespace: monitoring
spec:
  groups:
    - name: fraud.model.ab
      rules:
        - record: fraud_scorer:prediction_rate:by_version
          expr: |
            sum by (model_version, decision) (
              rate(fraud_scorer_predictions_total[5m])
            )

        - record: fraud_scorer:latency_p99:by_version
          expr: |
            histogram_quantile(0.99,
              sum by (model_version, le) (
                rate(fraud_scorer_request_duration_seconds_bucket[5m])
              )
            )

        - alert: ChallengerModelHigherErrorRate
          expr: |
            fraud_scorer:error_rate:by_version{model_version="v2"}
            > fraud_scorer:error_rate:by_version{model_version="v1"} * 1.5
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Challenger fraud model (v2) has higher error rate than control"
```

### Pattern 6 — MLflow Experiment Tracking and Model Registry
```python
# ml/experiment_tracking.py — structured experiment management

import mlflow
import mlflow.sklearn
from mlflow.tracking import MlflowClient

MLFLOW_TRACKING_URI = "http://mlflow.ml-platform.svc.cluster.local:5000"
mlflow.set_tracking_uri(MLFLOW_TRACKING_URI)

def run_experiment(
    experiment_name: str,
    params: dict,
    model,
    metrics: dict,
    feature_names: list[str],
) -> str:
    """Log an experiment run and return the run ID."""
    mlflow.set_experiment(experiment_name)

    with mlflow.start_run() as run:
        mlflow.log_params(params)
        mlflow.log_metrics(metrics)
        mlflow.log_param("feature_names", ",".join(feature_names))

        # Log model with input signature for serving validation
        from mlflow.models.signature import infer_signature
        import numpy as np

        sample_input = np.zeros((1, len(feature_names)))
        signature = infer_signature(sample_input, model.predict_proba(sample_input))

        mlflow.sklearn.log_model(
            model,
            artifact_path="model",
            signature=signature,
            input_example=sample_input,
        )

        mlflow.set_tags({
            "feature_store": "feast",
            "training_data_version": params.get("data_version", "unknown"),
        })

        return run.info.run_id


def promote_to_production(model_name: str, run_id: str, min_auc: float = 0.88) -> None:
    """Promote a model version to production if it meets the quality gate."""
    client = MlflowClient()

    # Find the model version registered in this run
    versions = client.search_model_versions(f"run_id='{run_id}'")
    if not versions:
        raise ValueError(f"No model registered for run {run_id}")

    version = versions[0]
    auc = float(client.get_run(run_id).data.metrics.get("val_auc", 0))

    if auc < min_auc:
        raise ValueError(f"AUC {auc:.4f} below threshold {min_auc}. Not promoting.")

    # Archive current production model
    current_prod = client.get_latest_versions(model_name, stages=["Production"])
    for v in current_prod:
        client.transition_model_version_stage(
            name=model_name,
            version=v.version,
            stage="Archived",
        )

    # Promote new version
    client.transition_model_version_stage(
        name=model_name,
        version=version.version,
        stage="Production",
    )
    print(f"Promoted {model_name} v{version.version} to Production (AUC={auc:.4f})")
```

---

## Anti-Patterns

### 1. Training-Serving Skew
Computing `avg_transaction_value_7d` differently in the training pipeline vs the serving code. The model sees different inputs at serving time than it was trained on.

**Fix**: feature store — define the computation once; both training and serving call the same definition.

### 2. No Model Registry — "Deploy the Latest Script"
Deploying models by manually running a training script and copying a pickle file to a server. No versioning, no rollback, no quality gate.

**Fix**: MLflow or similar. Every training run is tracked; only models above quality thresholds reach production; rollback is one command.

### 3. No Drift Monitoring
Model trained on January data. By July, customer behaviour has shifted. Model silently degrades. No one notices until business metrics tank.

**Fix**: automated daily drift reports (Evidently, WhyLabs). Alert when feature distribution or prediction distribution drifts significantly from the training baseline.

### 4. Batch Training Pipeline That Cannot Be Retrained Incrementally
Training pipeline takes 8 hours on 6 months of data. When drift is detected, retraining takes 8 hours. Stale model for too long.

**Fix**: windowed training with incremental updates. Keep the pipeline fast enough to retrain daily if needed.

### 5. Shadow Mode Skipped During Model Rollout
New model deployed directly to 100% production traffic without shadow testing. If the model behaves differently, you discover it via user complaints.

**Fix**: shadow mode (run both models, log both outputs, return only control model's result) → canary (5% traffic) → full rollout with automated metrics gate.

### 6. Features Computed at Request Time from Raw Data
Computing complex aggregations (7-day rolling averages) synchronously during a fraud check adds 200–500ms to the p99 latency.

**Fix**: pre-materialise features in the online store. Features are computed asynchronously, materialised to Redis; the serving path does a single millisecond lookup.

---

## Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| Features needed in < 10ms | Online feature store (Feast + Redis) |
| Features only for training | Offline feature store (S3 Parquet + Feast) |
| Experiment comparison across team | MLflow tracking server |
| Model quality gate before deploy | MLflow registry stage transitions with metric checks |
| Low-latency inference (< 50ms) | BentoML or Triton Inference Server |
| LLM serving with high throughput | vLLM with continuous batching |
| A/B testing between model versions | Istio VirtualService traffic weights |
| Detect when to retrain | Evidently drift reports + scheduled monitoring |
| Training on GPU | Kubeflow with GPU node pools |
| Reproducible training runs | Kubeflow Pipelines or MLflow Projects |

---

## Proficiency Levels

### Novice
- Understands the ML lifecycle (train → evaluate → deploy → monitor)
- Can train a model with scikit-learn and log metrics to MLflow
- Knows what a feature store is and why training-serving skew happens

### Intermediate
- Uses Feast to define features; retrieves historical features for training
- Logs experiments to MLflow; compares runs; promotes models via registry stages
- Deploys a model as a REST API with BentoML
- Runs basic drift detection with Evidently

### Advanced
- Builds end-to-end Kubeflow training pipelines with quality gates
- Implements online feature materialisation and serving with Feast + Redis
- Runs A/B tests between model versions with Istio traffic splitting
- Monitors model drift in production; triggers automated retraining when drift detected
- Implements shadow mode rollouts before full production deployment

### Expert
- Designs the full ML platform architecture: feature store, training, registry, serving, monitoring
- Operates LLM serving at scale with vLLM (continuous batching, tensor parallelism)
- Implements multi-armed bandit for adaptive model traffic allocation
- Designs feedback loops: production labels → retraining → automated promotion
- Builds platform self-service: ML engineers deploy models without platform team involvement

---

## AI Prompts

1. **Feature store design**: "I'm building a fraud detection model. I need features: 7-day transaction count, 30-day average amount, days since last transaction, and a pre-computed fraud score. Design a Feast feature view for these features. How should I handle the point-in-time join to prevent data leakage?"

2. **Training pipeline**: "Convert my training script into a Kubeflow Pipeline with these steps: fetch features, train model, evaluate against validation set, register if AUC > 0.85. Show the full pipeline YAML or Python DSL."

3. **Drift monitoring**: "My fraud model was trained in January. Write an Evidently drift check that compares the production feature distributions from last week against the training data. What thresholds should trigger a retraining alert?"

4. **Model serving**: "I need to serve a fraud scoring model with p99 < 20ms. The model needs 5 pre-computed features from a feature store. Design the serving architecture and show the BentoML service definition."

5. **A/B test setup**: "I want to test a new fraud model (v2) against the current production model (v1) at 20% traffic. Show the Istio configuration and Prometheus recording rules to compare block rate, false positive rate, and latency between versions."

---

## References

- Feast documentation — docs.feast.dev — feature store setup and patterns
- MLflow documentation — mlflow.org — experiment tracking, model registry
- Kubeflow Pipelines documentation — kubeflow.org/docs/components/pipelines
- BentoML documentation — docs.bentoml.com — model serving
- vLLM documentation — docs.vllm.ai — LLM serving
- Evidently documentation — evidentlyai.com — data and model drift
- Chip Huyen — *Designing Machine Learning Systems* (O'Reilly, 2022)
- Google Machine Learning Engineering — *MLOps: Continuous delivery and automation pipelines in ML*
- Made With ML — madewithml.com — practical MLOps patterns
