# COMMANDS

## 0. Environment

```bash
export REGION=<region>
export ACCOUNT=<account-id>
export BUCKET=<bucket-name>
export FN=<function-name>
export ROLE=<role-name>
export DB=<your-db-name>
export WG=<workgroup-name>
```

## 1. Bucket

```bash
aws s3api create-bucket --bucket $BUCKET --region $REGION

aws s3api put-public-access-block \
  --bucket $BUCKET \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

## 2. Execution role

```bash
aws iam create-role \
  --role-name $ROLE \
  --assume-role-policy-document file://policies/trust-policy.json

sed "s|\$BUCKET|$BUCKET|g; s|\$ACCOUNT|$ACCOUNT|g; s|\$REGION|$REGION|g" \
  policies/lambda-policy.json > /tmp/lambda-policy.json

aws iam put-role-policy \
  --role-name $ROLE \
  --policy-name etl-transform-policy \
  --policy-document file:///tmp/lambda-policy.json

aws iam get-role --role-name $ROLE --query 'Role.Arn'
```

## 3. Lambda

```bash
zip -j function.zip src/handler.py

aws lambda create-function \
  --function-name $FN \
  --runtime python3.12 \
  --handler handler.lambda_handler \
  --role arn:aws:iam::$ACCOUNT:role/$ROLE \
  --zip-file fileb://function.zip \
  --timeout 60 \
  --memory-size 1024 \
  --layers arn:aws:lambda:$REGION:336392948345:layer:AWSSDKPandas-Python312:16

aws lambda update-function-code \
  --function-name $FN \
  --zip-file fileb://function.zip
```

## 4. S3 trigger

```bash
aws lambda add-permission \
  --function-name $FN \
  --statement-id s3-invoke \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn arn:aws:s3:::$BUCKET \
  --source-account $ACCOUNT

aws s3api put-bucket-notification-configuration \
  --bucket $BUCKET \
  --notification-configuration file://policies/notification.json

aws s3api get-bucket-notification-configuration --bucket $BUCKET
```

## 5. Run the pipeline

```bash
aws s3 cp data/online-sales-data.csv s3://$BUCKET/raw/

aws logs tail /aws/lambda/$FN --follow

aws s3 ls s3://$BUCKET/processed/ --recursive
```

## 6. Glue database and table

```bash
aws glue create-database --database-input Name=$DB

sed "s|\$BUCKET|$BUCKET|g" glue/table-input.json > /tmp/table-input.json

aws glue create-table \
  --database-name $DB \
  --table-input file:///tmp/table-input.json

aws glue get-table --database-name $DB --name sales \
  --query 'Table.[StorageDescriptor.Location,Parameters]'
```

## 7. Athena workgroup

```bash
sed "s|\$BUCKET|$BUCKET|g" athena/workgroup-config.json > /tmp/workgroup-config.json

aws athena create-work-group \
  --name $WG \
  --description "Serverless ETL project queries; 1GB scan cap" \
  --configuration file:///tmp/workgroup-config.json

aws athena get-work-group --work-group $WG --query 'WorkGroup.Configuration'
```

## 8. Queries

```bash
aws athena start-query-execution \
  --work-group $WG \
  --query-execution-context Database=$DB \
  --query-string "SELECT product_category, SUM(total_revenue) AS revenue, SUM(units_sold) AS units FROM sales GROUP BY product_category ORDER BY revenue DESC"

aws athena start-query-execution \
  --work-group $WG \
  --query-execution-context Database=$DB \
  --query-string "SELECT product_category, SUM(total_revenue) AS revenue, SUM(units_sold) AS units FROM sales WHERE region = 'europe' GROUP BY product_category ORDER BY revenue DESC"

aws athena get-query-execution \
  --query-execution-id <query-execution-id> \
  --query 'QueryExecution.[Status.State,Statistics.DataScannedInBytes]'

aws athena get-query-results \
  --query-execution-id <query-execution-id> \
  --query 'ResultSet.Rows'
```

## 9. Teardown

```bash
chmod +x teardown.sh
./teardown.sh
```