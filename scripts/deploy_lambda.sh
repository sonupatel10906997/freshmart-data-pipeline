#!/bin/bash

set -euo pipefail

# Resolve all project paths once so the script can be run from any directory.
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$APP_ROOT/build"
PACKAGE_DIR="$BUILD_DIR/package"
ZIP_FILE_ORCHESTRATOR="$APP_ROOT/deployment_package_orchestrator.zip"
ZIP_FILE_WORKER="$APP_ROOT/deployment_package_worker.zip"
ROLE_POLICY_NAME="s3_read_write_policy"
ROLE_POLICY_DURABLE_EXECUTION_NAME="lamba-with-durable-execution-policy"
TRUST_POLICY_FILE="$BUILD_DIR/trust-policy.json"
INLINE_POLICY_FILE="$BUILD_DIR/s3-access-policy.json"
INLINE_DURABLE_EXECUTION_POLICY_FILE="$BUILD_DIR/lambda-execution-durable-policy.json"


# These values are shared by both environments.
LAMBDA_HANDLER_ORCHESTRATOR="${LAMBDA_HANDLER:-pipeline_orchestrator.lambda_handler}"
LAMBDA_HANDLER_WORKER="${LAMBDA_HANDLER:-data_transformer_worker.lambda_handler}"
LAMBDA_RUNTIME="${LAMBDA_RUNTIME:-python3.13}"
LAMBDA_TIMEOUT="${LAMBDA_TIMEOUT:-60}"
LAMBDA_MEMORY="${LAMBDA_MEMORY:-512}"

# CodeBuild provides the source branch via CODEBUILD_WEBHOOK_HEAD_REF.
# The branch decides whether we deploy the dev or prod Lambda.
BRANCH_REF="${CODEBUILD_WEBHOOK_HEAD_REF:-}"
DEPLOY_ENV="${DEPLOY_ENV:-}"

if [[ -z "$DEPLOY_ENV" ]]; then
  case "$BRANCH_REF" in
    refs/heads/dev)
      DEPLOY_ENV="DEV"
      ;;
    refs/heads/main)
      DEPLOY_ENV="PROD"
      ;;
    *)
      echo "Unsupported branch ref: ${BRANCH_REF:-unknown}. Only dev and main are supported."
      exit 1
      ;;
  esac
fi

# Look up environment-specific variables such as DEV_FUNCTION_NAME or
# PROD_FUNCTION_NAME using the resolved DEPLOY_ENV prefix.
S3_SOURCE_BUCKET_VAR="${DEPLOY_ENV}_S3_SOURCE_BUCKET"
S3_TARGET_BUCKET_VAR="${DEPLOY_ENV}_S3_TARGET_BUCKET"
FUNCTION_NAME_ORCHESTRATOR_VAR="${DEPLOY_ENV}_ORCHESTRATOR_FUNCTION_NAME"
FUNCTION_NAME_WORKER_VAR="${DEPLOY_ENV}_WORKER_FUNCTION_NAME"
IAM_ROLE_NAME_VAR="${DEPLOY_ENV}_IAM_ROLE_NAME"
AWS_REGION_VAR="${DEPLOY_ENV}_AWS_REGION"

S3_SOURCE_BUCKET="${!S3_SOURCE_BUCKET_VAR:-}"
S3_TARGET_BUCKET="${!S3_TARGET_BUCKET_VAR:-}"
FUNCTION_NAME_ORCHESTRATOR="${!FUNCTION_NAME_ORCHESTRATOR_VAR:-}"
FUNCTION_NAME_WORKER="${!FUNCTION_NAME_WORKER_VAR:-}"
IAM_ROLE_NAME="${!IAM_ROLE_NAME_VAR:-}"
AWS_REGION="${!AWS_REGION_VAR:-}"

if [[ -z "$S3_SOURCE_BUCKET" || -z "$S3_TARGET_BUCKET" || -z "$FUNCTION_NAME_ORCHESTRATOR" || -z "$FUNCTION_NAME_WORKER" || -z "$IAM_ROLE_NAME" || -z "$AWS_REGION" ]]; then
  echo "Missing environment configuration for $DEPLOY_ENV"
  echo "Required variables: $S3_SOURCE_BUCKET_VAR, $S3_TARGET_BUCKET_VAR, $FUNCTION_NAME_ORCHESTRATOR_VAR, $FUNCTION_NAME_WORKER_VAR $IAM_ROLE_NAME_VAR, $AWS_REGION_VAR"
  exit 1
fi

echo "Resolved deployment environment: $DEPLOY_ENV"
echo "Target ORCHESTRATOR Lambda function: $FUNCTION_NAME_ORCHESTRATOR"
echo "Target WORKER Lambda function: $FUNCTION_NAME_WORKER"
echo "Target IAM role: $IAM_ROLE_NAME"
echo "Target Read S3 bucket permission: $S3_SOURCE_BUCKET"
echo "Target Put S3 bucket permission: $S3_TARGET_BUCKET"
echo "Target AWS region: $AWS_REGION"

echo "Clearing old deployment packages"
rm -rf "$BUILD_DIR" "$ZIP_FILE_ORCHESTRATOR" "$ZIP_FILE_WORKER"
mkdir -p "$PACKAGE_DIR/tmp"

echo "Preparing to create s3 bucket if not exist"
# Create S3 buckets if they do not already exist
for bucket in "$S3_SOURCE_BUCKET" "$S3_TARGET_BUCKET"; do
    if aws s3api head-bucket --bucket "$bucket" --region "$AWS_REGION" >/dev/null 2>&1; then
        echo "S3 bucket $bucket already exists"
    else
        echo "Creating S3 bucket $bucket"
        aws s3api create-bucket \
            --bucket "$bucket" \
            --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
        
        # Block all public access
        aws s3api put-public-access-block \
            --bucket "$bucket" \
            --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null
        
        echo "S3 bucket $bucket created successfully"
    fi
done

echo "Preparing deployment package for $FUNCTION_NAME_ORCHESTRATOR"
# Install pandas and any future dependencies into the Lambda package directory.
pip install --upgrade pip
cp "$APP_ROOT/lambdas/orchestrator/pipeline_orchestrator.py" "$PACKAGE_DIR"

(
  cd "$PACKAGE_DIR"
  zip -rq "$ZIP_FILE_ORCHESTRATOR" .
  rm -f "$PACKAGE_DIR/pipeline_orchestrator.py"
)

echo "Preparing deployment package for $FUNCTION_NAME_WORKER"
# Install pandas and any future dependencies into the Lambda package directory.
pip install --target "$PACKAGE_DIR/temp" -r "$APP_ROOT/requirements.txt"
cp "$APP_ROOT/lambdas/transformer/data_transformer_worker.py" "$PACKAGE_DIR/temp"

(
  cd "$PACKAGE_DIR/temp"
  zip -rq "../$ZIP_FILE_WORKER" .
)


# Trust policy: allows AWS Lambda to assume the execution role.
cat > "$TRUST_POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Inline policy: allows the Lambda to read objects from the environment bucket.
cat > "$INLINE_POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_SOURCE_BUCKET}/*",
        "arn:aws:s3:::${S3_TARGET_BUCKET}/*"
      ]
    }
  ]
}
EOF

cat > "$INLINE_DURABLE_EXECUTION_POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lambda:CheckpointDurableExecution",
        "lambda:GetDurableExecutionState"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# Reuse the role if it already exists; otherwise create it and attach the
# standard CloudWatch logging policy used by Lambda execution roles.
if aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
  echo "IAM role $IAM_ROLE_NAME already exists"
else
  echo "Creating IAM role $IAM_ROLE_NAME"
  aws iam create-role \
    --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_POLICY_FILE" >/dev/null
  
  POLICIES=(
    "arn:aws:iam::aws:policy/AWSLambdaBasicExecutionRole"
    "arn:aws:iam::aws:policy/service-role/AWSLambdaRole"
    )

    for policy in "${POLICIES[@]}"; do
        aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn "$policy" >/dev/null
    done
  
fi

aws iam put-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-name "$ROLE_POLICY_NAME" \
  --policy-document "file://$INLINE_POLICY_FILE" >/dev/null

aws iam put-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-name "$ROLE_POLICY_DURABLE_EXECUTION_NAME" \
  --policy-document "file://$INLINE_DURABLE_EXECUTION_POLICY_FILE" >/dev/null

ROLE_ARN="$(aws iam get-role --role-name "$IAM_ROLE_NAME" --query 'Role.Arn' --output text)"

# IAM changes are not always visible immediately, so wait briefly before
# creating or updating the Lambda function with the role ARN.
echo "Waiting briefly for IAM role propagation"
sleep 10

# Update the function if it exists; otherwise create it from scratch.
if aws lambda get-function --function-name "$FUNCTION_NAME_ORCHESTRATOR" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Updating existing Lambda function $FUNCTION_NAME_ORCHESTRATOR"
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME_ORCHESTRATOR" \
    --zip-file "fileb://$ZIP_FILE_ORCHESTRATOR" \
    --region "$AWS_REGION" >/dev/null

  # Lambda blocks configuration changes while a code update is still being
  # applied, so wait until the previous update finishes before continuing.
  echo "Waiting for code update to complete before updating configuration"
  aws lambda wait function-updated-v2 \
    --function-name "$FUNCTION_NAME_ORCHESTRATOR" \
    --region "$AWS_REGION"

  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME_ORCHESTRATOR" \
    --role "$ROLE_ARN" \
    --handler "$LAMBDA_HANDLER_ORCHESTRATOR" \
    --runtime "$LAMBDA_RUNTIME" \
    --timeout "$LAMBDA_TIMEOUT" \
    --memory-size "$LAMBDA_MEMORY" \
    --environment "Variables={MAX_PREVIEW_ROWS=5}" \
    --region "$AWS_REGION" >/dev/null

  echo "Waiting for configuration update to complete"
  aws lambda wait function-updated-v2 \
    --function-name "$FUNCTION_NAME_ORCHESTRATOR" \
    --region "$AWS_REGION"
else
  echo "Creating Lambda function $FUNCTION_NAME_ORCHESTRATOR"
  aws lambda create-function \
    --function-name "$FUNCTION_NAME_ORCHESTRATOR" \
    --runtime "$LAMBDA_RUNTIME" \
    --role "$ROLE_ARN" \
    --handler "$LAMBDA_HANDLER_ORCHESTRATOR" \
    --durable-config '{"ExecutionTimeout": 3600}' \
    --zip-file "fileb://$ZIP_FILE_ORCHESTRATOR" \
    --timeout "$LAMBDA_TIMEOUT" \
    --memory-size "$LAMBDA_MEMORY" \
    --environment "Variables={MAX_PREVIEW_ROWS=5}" \
    --region "$AWS_REGION" >/dev/null

  echo "Waiting for new Lambda function to become active"
  aws lambda wait function-active-v2 \
    --function-name "$FUNCTION_NAME_ORCHESTRATOR" \
    --region "$AWS_REGION"
fi

echo "Deployment completed for Lambda function $FUNCTION_NAME_ORCHESTRATOR"

# Update the function if it exists; otherwise create it from scratch.
if aws lambda get-function --function-name "$FUNCTION_NAME_WORKER" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Updating existing Lambda function $FUNCTION_NAME_WORKER"
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME_WORKER" \
    --zip-file "fileb://$ZIP_FILE_WORKER" \
    --region "$AWS_REGION" >/dev/null

  # Lambda blocks configuration changes while a code update is still being
  # applied, so wait until the previous update finishes before continuing.
  echo "Waiting for code update to complete before updating configuration"
  aws lambda wait function-updated-v2 \
    --function-name "$FUNCTION_NAME_WORKER" \
    --region "$AWS_REGION"

  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME_WORKER" \
    --role "$ROLE_ARN" \
    --handler "$LAMBDA_HANDLER_WORKER" \
    --runtime "$LAMBDA_RUNTIME" \
    --timeout "$LAMBDA_TIMEOUT" \
    --memory-size "$LAMBDA_MEMORY" \
    --environment "Variables={MAX_PREVIEW_ROWS=5}" \
    --region "$AWS_REGION" >/dev/null

  echo "Waiting for configuration update to complete"
  aws lambda wait function-updated-v2 \
    --function-name "$FUNCTION_NAME_WORKER" \
    --region "$AWS_REGION"
else
  echo "Creating Lambda function $FUNCTION_NAME_WORKER"
  aws lambda create-function \
    --function-name "$FUNCTION_NAME_WORKER" \
    --runtime "$LAMBDA_RUNTIME" \
    --role "$ROLE_ARN" \
    --handler "$LAMBDA_HANDLER_WORKER" \
    --zip-file "fileb://$ZIP_FILE_WORKER" \
    --timeout "$LAMBDA_TIMEOUT" \
    --memory-size "$LAMBDA_MEMORY" \
    --environment "Variables={MAX_PREVIEW_ROWS=5}" \
    --region "$AWS_REGION" >/dev/null

  echo "Waiting for new Lambda function to become active"
  aws lambda wait function-active-v2 \
    --function-name "$FUNCTION_NAME_WORKER" \
    --region "$AWS_REGION"
fi

echo "Deployment completed for Lambda function $FUNCTION_NAME_WORKER"

