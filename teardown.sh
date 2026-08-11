#!/usr/bin/env bash
#
# Tears down every resource created by the serverless-etl-athena build.
# Exits non-zero if anything failed or survived.

set -uo pipefail

REGION="${REGION:-us-east-1}"
BUCKET="${BUCKET:?set BUCKET}"
FN="${FN:-etl-transform}"
ROLE="${ROLE:-etl-transform-role}"
DB="${DB:?set DB}"
TABLE="${TABLE:-sales}"
WG="${WG:-etl-athena-wg}"

FAILURES=0

# Matches the various ways AWS says "that doesn't exist". Anything not
# matching this is a real failure and gets printed in full.
NOT_FOUND_RE='NoSuchEntity|ResourceNotFound|EntityNotFound|NoSuchBucket|NotFoundException|WorkGroupNotFound|does not exist|not found'

# try: run a command, classify the outcome, never hide the reason.
try() {
  local label="$1"; shift
  local err
  if err=$("$@" 2>&1); then
    echo "  [deleted]  ${label}"
  elif [[ "$err" =~ $NOT_FOUND_RE ]]; then
    echo "  [absent]   ${label}"
  else
    echo "  [FAILED]   ${label}"
    echo "             ${err}" | head -n 3
    FAILURES=1
  fi
}

echo "Region:  ${REGION}"
echo "Bucket:  ${BUCKET}"
echo "Lambda:  ${FN}"
echo "Role:    ${ROLE}"
echo "Glue DB: ${DB}"
echo "Athena:  ${WG}"
echo
read -r -p "Delete all of the above? [y/N] " reply
[[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "Aborted."; exit 1; }
echo

echo "== Athena =="
try "workgroup ${WG}" \
  aws athena delete-work-group --work-group "$WG" --recursive-delete-option

echo "== Glue =="
try "table ${DB}.${TABLE}" \
  aws glue delete-table --database-name "$DB" --name "$TABLE"
try "database ${DB}" \
  aws glue delete-database --name "$DB"

echo "== Trigger =="
try "bucket notification config" \
  aws s3api put-bucket-notification-configuration \
    --bucket "$BUCKET" --notification-configuration '{}'

echo "== Lambda =="
try "function ${FN}" \
  aws lambda delete-function --function-name "$FN"
try "log group /aws/lambda/${FN}" \
  aws logs delete-log-group --log-group-name "/aws/lambda/${FN}"

echo "== IAM =="
# Policy names are discovered, not assumed. A role cannot be deleted while
# any policy is still inline or attached, so both lists must be drained.
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then

  for p in $(aws iam list-role-policies --role-name "$ROLE" \
               --query 'PolicyNames[]' --output text); do
    try "inline policy ${p}" \
      aws iam delete-role-policy --role-name "$ROLE" --policy-name "$p"
  done

  for arn in $(aws iam list-attached-role-policies --role-name "$ROLE" \
                 --query 'AttachedPolicies[].PolicyArn' --output text); do
    try "detach ${arn}" \
      aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$arn"
    # Only customer-managed policies can be deleted; AWS-managed ones cannot.
    if [[ "$arn" != arn:aws:iam::aws:policy/* ]]; then
      try "policy ${arn}" aws iam delete-policy --policy-arn "$arn"
    fi
  done

  try "role ${ROLE}" aws iam delete-role --role-name "$ROLE"
else
  echo "  [absent]   role ${ROLE}"
fi

echo "== S3 =="
try "objects in ${BUCKET}" \
  aws s3 rm "s3://${BUCKET}" --recursive

# If the bucket is versioned, the delete above leaves versions and delete
# markers behind and delete-bucket will refuse. Harmless no-op if it isn't.
for kind in Versions DeleteMarkers; do
  while :; do
    payload=$(aws s3api list-object-versions \
      --bucket "$BUCKET" --max-keys 500 --output json \
      --query "{Objects: ${kind}[].{Key:Key,VersionId:VersionId}}" 2>/dev/null) || break
    [[ -z "$payload" || "$payload" == *'"Objects": null'* ]] && break
    aws s3api delete-objects --bucket "$BUCKET" --delete "$payload" >/dev/null 2>&1 || break
    echo "  [deleted]  a batch of ${kind}"
  done
done

try "bucket ${BUCKET}" \
  aws s3api delete-bucket --bucket "$BUCKET"

echo
echo "== Verifying =="
survived() { echo "  [SURVIVED] $1"; FAILURES=1; }

aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 \
  && survived "bucket ${BUCKET}" || echo "  [clear]    bucket"

aws lambda get-function --function-name "$FN" >/dev/null 2>&1 \
  && survived "lambda ${FN}" || echo "  [clear]    lambda"

aws glue get-database --name "$DB" >/dev/null 2>&1 \
  && survived "glue database ${DB}" || echo "  [clear]    glue database"

aws athena get-work-group --work-group "$WG" >/dev/null 2>&1 \
  && survived "workgroup ${WG}" || echo "  [clear]    athena workgroup"

aws iam get-role --role-name "$ROLE" >/dev/null 2>&1 \
  && survived "role ${ROLE}" || echo "  [clear]    iam role"

echo
if (( FAILURES )); then
  echo "TEARDOWN INCOMPLETE — resolve the items above before closing the session."
  exit 1
fi
echo "Teardown complete."