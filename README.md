# serverless-etl-athena

> Event-driven ETL pipeline that transforms CSV files uploaded to S3 into cleaned, validated, partitioned Parquet files for querying with Amazon Athena.

---

## Architecture

```
CSV upload ──► S3 raw/ ──► S3 event notification ──► Lambda (etl-transform)
                                                          │
                                    pandas clean + validate + groupby(region)
                                                          │
                                                          ▼
                            S3 processed/region=<region>/<file>.parquet
                                                          │
                                    Glue Data Catalog (external table, partition projection)
                                                          │
                                                          ▼
                                    Athena workgroup ──► S3 athena-results/
```

### Request Flow

Uploading a `.csv` under `raw/` triggers an S3 `ObjectCreated:*` notification. Lambda reads the file, normalizes and validates the data, groups it by region, and writes Snappy-compressed Parquet files to `processed/region=<region>/`.

The Glue table uses partition projection, so no crawler or `MSCK REPAIR` is required. Athena queries the processed Parquet files directly from S3.

---

## Features

- S3 event trigger filtered to `raw/*.csv`, with an additional prefix check in the handler.
- Column and region normalization with required-field validation.
- Explicit type casting to match the Glue schema.
- Revenue integrity check for `total_revenue != units_sold * unit_price` within ±$0.01.
- Hive-style partitioned Parquet output with Snappy compression.
- Glue external table using partition projection.
- Athena workgroup with a 1 GiB per-query scan limit.

---

## Design Decisions & Trade-offs

- **Partition by `region`, not `date`.** Three region partitions produce more practical file sizes than hundreds of single-row date partitions.
- **Partition projection instead of a Glue crawler.** Removes crawler cost and write-to-query delay, but new region values must be added to the projection configuration.
- **Parquet + Snappy instead of CSV.** Reduces storage and Athena scan volume through compression and columnar reads.
- **AWS SDK for Pandas Lambda layer.** Avoids packaging pandas and pyarrow with the function. The layer version is pinned to the Python runtime.
- **Validation warns instead of rejecting.** Revenue mismatches are logged without blocking otherwise usable records.
- **Athena workgroup enforcement.** Prevents clients from overriding the result location or bypassing the query scan limit.

---

## Tech Stack

- AWS Lambda — Python 3.13
- Amazon S3
- AWS Glue Data Catalog
- Amazon Athena
- pandas / pyarrow
- boto3

---

## Prerequisites

- AWS account with permissions for Lambda, S3, IAM, Glue, and Athena
- AWS CLI v2 configured
- Python 3.13 for local development
- S3 prefixes: `raw/`, `processed/`, and `athena-results/`

---

## Deployment

Infrastructure is deployed with the AWS CLI using the JSON configuration files in this repository.

No Infrastructure as Code configuration is included.

Before deployment, configure the required bucket name, AWS account ID, region, and managed AWS SDK for Pandas layer version.

---

## Usage

Upload a CSV to the `raw/` prefix:

```bash
aws s3 cp data/online-sales-data.csv s3://$BUCKET/raw/
```

Query the processed dataset with Athena:

```bash
aws athena start-query-execution --work-group etl \
  --query-string "SELECT region, SUM(total_revenue) AS revenue FROM sales_db.sales GROUP BY region"
```

Example Lambda output:

```text
processing s3://$BUCKET/raw/online-sales-data.csv
rows: 240 -> 240
wrote processed/region=asia/online-sales-data.parquet (80 rows)
wrote processed/region=europe/online-sales-data.parquet (80 rows)
wrote processed/region=north_america/online-sales-data.parquet (80 rows)
```

---

## Cost Considerations

Athena charges based on data scanned. Parquet, compression, and region partitioning reduce scan volume, while the 1 GiB workgroup limit protects against unexpectedly large queries.

At the sample workload, Lambda and S3 costs are negligible.

---

## Testing

**Verified**

- End-to-end processing of the 240-row sample dataset.
- 240 rows in and 240 rows out.
- No revenue mismatches above the $0.01 threshold.
- Three expected region partitions written.

**Not Covered**

- Automated unit tests.
- Multi-record S3 events; only `Records[0]` is processed.
- Files exceeding Lambda memory or execution limits.
- Reprocessing the same filename overwrites existing output.
- Automated infrastructure teardown.

---

## Monitoring

Lambda writes processing output to CloudWatch Logs, and the Athena workgroup publishes query metrics.

No alarms or dashboards are configured.

---

## Security

- Lambda access is scoped to `GetObject` on `raw/*` and `PutObject` on `processed/*`.
- Log permissions are scoped to the function's CloudWatch log group.
- S3 notifications are filtered to `raw/` and `.csv`, with an additional prefix check in the handler.
- Athena enforces its configured query-result location.

Not implemented: `aws:SourceAccount` condition, S3 bucket policy, KMS encryption, or VPC configuration.

---

## Future Improvements

- Replace CLI deployment with Terraform.
- Add unit tests for malformed and invalid input.
- Process every record in multi-record S3 events.
- Add idempotency based on S3 object version.
- Send rejected rows to a `quarantine/` prefix.
- Improve handling of new partition values.
- Add CloudWatch alarms for Lambda errors.