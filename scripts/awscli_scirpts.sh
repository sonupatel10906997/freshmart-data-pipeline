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

aws s3api put-bucket-notification-configuration \
        --bucket "dev-freshdatamart-pipeline-source-735910967129" \
        --region "us-east-1" \
        --notification-configuration file:///dev/stdin <<EOF
{
    "LambdaFunctionConfigurations": [
        {
            "LambdaFunctionArn": "arn:aws:lambda:us-east-1:735910967129:function:dev-labmda-func-orchestrator-735910967129",
            "Events": ["s3:ObjectCreated:*"]
        }
    ]
}
EOF

aws lambda get-policy \
    --function-name "dev-labmda-func-orchestrator-735910967129" \
    --region "us-east-1" \
    --output text