aws s3 mb s3://dev-freshmart-data-pipeline-raw-bucket-10906997
# test-failed
# test1 
ws s3api get-bucket-notification-configuration \
    --bucket "dev-freshdatamart-pipeline-source-735910967129" \
    --region "us-east-1" 2>/dev/null

aws lambda get-function \
    --function-name "dev-labmda-func-orchestrator-735910967129" \
    --region "us-east-1" \
    --query 'Configuration.FunctionArn' \
    --output text

aws lambda get-policy \
    --function-name "dev-labmda-func-orchestrator-735910967129" \
    --region "us-east-1" 2>/dev/null | grep -q "s3-trigger";

