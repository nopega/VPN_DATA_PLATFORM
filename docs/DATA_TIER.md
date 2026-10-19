# Data tiers and retention

Object storage only: where the data lives in S3, how it is laid out, how long
it is kept and which storage class it sits in as it ages. Block storage (EBS
volumes behind PersistentVolumeClaims) is listed in [COST.md](COST.md).

Each section says whether it is **applied** (in Terraform, running today) or
**designed** (the policy, written down, not yet put on a bucket). The gap is
deliberate and stated in section 5.

## 1. Buckets

Three buckets, one per kind of data. Every name carries the AWS account id,
because bucket names are global across all of AWS and this makes a collision
with someone else's bucket impossible.

| Bucket | Contents | Who can touch it | Created by |
|---|---|---|---|
| `vpn-data-platform-warehouse-<account>` | Iceberg tables: Parquet data files and metadata | only the Polaris **storage role**, which hands per-table credentials to Spark and Trino | `terraform/06_data_foundation` |
| `vpn-data-platform-logs-<account>` | Airflow task logs (`airflow/`), Spark event logs (`spark-events/`) | the Airflow role and the Spark role, each on its own prefix only | `terraform/06_data_foundation` |
| `vpn-data-platform-registry-<account>` | Harbor image layers | one IAM user, this bucket only | `terraform/08_registry` |

**Why separate buckets:** permissions are scoped per bucket and per prefix (no
engine can reach the logs, no log writer can reach a table), a lifecycle rule
cannot spill from one kind of data into another, and each bucket's cost shows
up on its own in Cost Explorer without extra tagging.

All three: private (public access blocked), encrypted at rest (SSE-S3), ACLs
off. Pods reach them through the S3 gateway endpoint in the VPC, so no byte of
S3 traffic crosses the NAT.

Prometheus metrics are **not** in S3. Prometheus keeps 7 days on its own EBS
volume; long-term metrics are a planned upgrade (see
[COMPONENTS.md](COMPONENTS.md#planned-upgrades)).

## 2. Warehouse layout — the path is the policy key

*Applied* (the layout) — the three namespaces the pipelines write into are
created by `bootstrap/spark.sh`.

Every table path has the same shape, **medallion layer / data category /
domain / table**, and each segment is an Iceberg namespace level:

```
s3://vpn-data-platform-warehouse-<account>/
├── bronze/                     raw, as ingested — the only copy that cannot be rebuilt
│   ├── financial/<domain>/<table>/
│   ├── transactional/<domain>/<table>/        ← in use
│   ├── operational/<domain>/<table>/
│   └── log/<domain>/<table>/
├── silver/                     cleaned, validated, de-duplicated
│   └── derived/<domain>/<table>/              ← in use
└── gold/                       aggregated for the people who read it
    └── aggregate/<domain>/<table>/            ← in use
```

So `bronze/transactional/<domain>/<table>/` is the table
`data_platform."bronze.transactional.<domain>".<table>` in Polaris. The
storage role's policy grants only `bronze/*`, `silver/*` and `gold/*`, so a
table created outside the layout cannot be written at all.

### Why two dimensions, not one

| Segment | Answers | Decides |
|---|---|---|
| medallion (`bronze` / `silver` / `gold`) | how far through processing the data is | whether it can be recomputed if lost |
| category (`financial`, `transactional`, …) | what kind of data it is | how long it must be kept, and whether automatic deletion is allowed at all |

They are independent: financial data is never deleted automatically whether it
sits in bronze or gold, and gold is recomputable whatever it was built from.
Medallion comes first because it changes least, and because it puts the
recomputable and non-recomputable halves of the bucket at the top level —
which is what matters when deciding what a lifecycle rule may delete.

`silver/` holds only `derived/` and `gold/` only `aggregate/`, so that second
segment says nothing new there. It stays anyway: one path shape means one
lifecycle pattern, one grant pattern and one parsing rule, instead of a special
case for two layers out of three.

Everything is lowercase: Trino lowercases unquoted identifiers, and a
namespace named `Bronze` would need quoting at every use.

## 3. Data categories (decide deletion only)

*Designed.*

| Category | Examples | Deletion policy |
|---|---|---|
| **Financial** | amounts, payment status | never automatic; removal needs explicit approval after the legal retention period |
| **Transactional** | events and status changes, trips, orders | automatic after a long window that covers disputes and audits (3 years) |
| **Operational** | state snapshots, locations | automatic, 180 days |
| **Log** | structured audit tables (who queried what) | 365 days — evidence, not debugging output |
| **Derived** (silver) | cleaned copies of bronze | reproducible from bronze; 3 years |
| **Aggregate** (gold) | daily summaries | tiny and cheap to keep; 5 years |

## 4. Age-based storage tiers (warehouse)

*Designed.*

S3 knows nothing about Iceberg partitions; it sees objects and the day each one
was written. Tiering by object age is therefore the only rule S3 can apply —
which matches how the data is used: recent partitions are queried constantly,
old ones rarely.

| Object age | Storage class |
|---|---|
| 0–90 days | S3 Standard |
| 90 days – 1 year | S3 Standard-IA |
| 1–3 years | S3 Glacier Instant Retrieval |
| 3+ years | Glacier Deep Archive (financial) or deletion (everything else, per section 3) |

The rules key on the **two-segment prefix**, because retention belongs to the
category, not to the layer:

```json
{
  "Rules": [
    { "ID": "financial", "Status": "Enabled", "Filter": { "Prefix": "bronze/financial/" },
      "Transitions": [ { "Days": 90, "StorageClass": "STANDARD_IA" },
                       { "Days": 365, "StorageClass": "GLACIER_IR" },
                       { "Days": 1095, "StorageClass": "DEEP_ARCHIVE" } ] },
    { "ID": "transactional", "Status": "Enabled", "Filter": { "Prefix": "bronze/transactional/" },
      "Transitions": [ { "Days": 90, "StorageClass": "STANDARD_IA" },
                       { "Days": 365, "StorageClass": "GLACIER_IR" } ],
      "Expiration": { "Days": 1095 } },
    { "ID": "operational", "Status": "Enabled", "Filter": { "Prefix": "bronze/operational/" },
      "Transitions": [ { "Days": 90, "StorageClass": "STANDARD_IA" } ],
      "Expiration": { "Days": 180 } },
    { "ID": "log-tables", "Status": "Enabled", "Filter": { "Prefix": "bronze/log/" },
      "Transitions": [ { "Days": 90, "StorageClass": "STANDARD_IA" } ],
      "Expiration": { "Days": 365 } },
    { "ID": "derived", "Status": "Enabled", "Filter": { "Prefix": "silver/derived/" },
      "Transitions": [ { "Days": 90, "StorageClass": "STANDARD_IA" },
                       { "Days": 365, "StorageClass": "GLACIER_IR" } ],
      "Expiration": { "Days": 1095 } },
    { "ID": "aggregate", "Status": "Enabled", "Filter": { "Prefix": "gold/aggregate/" },
      "Transitions": [ { "Days": 90, "StorageClass": "STANDARD_IA" },
                       { "Days": 365, "StorageClass": "GLACIER_IR" } ],
      "Expiration": { "Days": 1825 } },
    { "ID": "abort-incomplete-uploads", "Status": "Enabled", "Filter": {},
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 } }
  ]
}
```

- **Prefixes, not object tags.** A tag must be set by the writer on every
  object; a job started without the tag property silently writes objects no
  rule matches. A prefix is where the file *is*, so classification cannot be
  lost by a configuration mistake.
- **Financial has no `Expiration`** — only an approved manual process deletes it.
- **Reclassifying a table means moving its files** to another prefix and
  updating its Iceberg location: deliberate, as it should be when retention
  changes.
- **Iceberg needs its own housekeeping too.** S3 expiry deletes files; it does
  not know which files a table's current snapshot still references. Expiring
  snapshots and removing orphan files (Iceberg maintenance procedures) has to
  run *before* an S3 rule removes anything, or a rule can delete a file a live
  table still points at. This is the main reason the warehouse rules are not
  applied yet.

## 5. What is applied today

| Bucket | Rule in Terraform | Why that and not the design |
|---|---|---|
| warehouse | none | the design in section 4 needs Iceberg snapshot expiry running first (above); with one pipeline and days of data, nothing is old enough to tier |
| logs | everything **larger than 0 bytes** expires after **30 days**; incomplete uploads aborted after 7 | one rule is enough for two prefixes of debugging output. Zero-byte objects are excluded so the `spark-events/` directory marker survives — Spark refuses to start if `spark.eventLog.dir` does not exist |
| registry | incomplete uploads aborted after 7 days; **no expiry** | Harbor decides which layers to delete (tag retention + garbage collection). An S3 rule deleting a layer under it would corrupt an image silently until someone pulled it |

When the logs bucket gains a prefix that is evidence rather than debugging (a
Trino query audit log, for example), it gets its own longer rule — 365 days in
the design — instead of inheriting the 30-day one.
