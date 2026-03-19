import io
import logging 
from datetime import datetime, timezone
import json
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import ClientError
import pandas as pd

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SCHEMA_COLS = ["Invoice_id","Branch","City","Customer_type","Gender","Product_line","Unit_price","Quantity","Date","Payment","Rating"]
ALLOWED_EXTENSIONS = [".csv"]

# boto3 with retry config
S3_CLIENT = boto3.client("s3")


def read_csv_s3(bucketName: str, bucketKey: str)->tuple[io.BytesIO, int]:
    try:
        ext = "." + bucketKey.rsplit('.',1)[-1] if "." in bucketKey else ""
        if ext not in ALLOWED_EXTENSIONS:
            logger.error("UnSupportedFileFormat Exception. Expected: %s | Actual: %s",
                ALLOWED_EXTENSIONS,
                ext)
            
            raise Exception(
                f"UnSupportedFileFormat Exception. Expected: {ALLOWED_EXTENSIONS} | Actual: {ext}"
            )
        logger.info("Fetching s3://%s/%s", bucketName, bucketKey)
        obj = S3_CLIENT.get_object(Bucket= bucketName, Key= bucketKey)
        raw = obj['Body'].read()
        content_length = len(raw)
        logger.info(
            "Fetched s3://%s/%s - %d bytes", bucketName, bucketKey, content_length
        )

        return io.BytesIO(raw), content_length
    
    except ClientError as e:
        logger.error("Failed to read bucket s3://%s/%s - %s", bucketName, bucketKey, e.response["Error"]["Message"])
        raise 

def validate_csv(fileContent: io.BytesIO, bucketKey: str)-> dict:
    sales_df = pd.read_csv(fileContent, header=0)
    actual_cols = sales_df.columns.to_list()
    if actual_cols != SCHEMA_COLS:
        added_cols = set(actual_cols) - set(SCHEMA_COLS)
        removed_cols = set(SCHEMA_COLS) - set(actual_cols)

        logger.error(
            "Schema Drift Detected in %s | Added Colums: %s | Missing Columns : %s",
            bucketKey,
            added_cols,
            removed_cols
        )

        raise Exception(f"Schema Drift Detected in {bucketKey} | Added Cols : {added_cols} | Missing Cols: {removed_cols}")

    no_of_rows, no_of_cols = sales_df.shape
    rows_with_nulls = sales_df.isnull().any(axis=1).sum()
    duplicate_rows = sales_df.duplicated().sum()

    logger.info(
        "Validation passed for %s with %d rows, %d cols, %d rows with nulls and %d duplicate rows",
        bucketKey,
        no_of_rows,
        no_of_cols,
        rows_with_nulls,
        duplicate_rows
    )

    return {
        "row_count"             : no_of_rows,
        "cols_count"            : no_of_cols,
        "rows_with_nulls"       : rows_with_nulls,
        "duplicate_rows"        : duplicate_rows
    }



def lambda_handler(event, context):
    try:
        logger.info("Raw event received: %s", json.dumps(event, indent=4, default=str))

        bucketName = event["Records"][0]["s3"]["bucket"]["name"]
        bucketKey = unquote_plus(event["Records"][0]["s3"]["object"]["key"])
        filesize = event["Records"][0]["s3"]["object"]["size"]
        event_ts = event["Records"][0]["eventTime"]

        processing_ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        filecontent, filelength = read_csv_s3(bucketName, bucketKey)
        metrics = validate_csv(filecontent, bucketKey)

        payload = {
            "filename"              : f"s3://{bucketName}/{bucketKey}",
            "event_trigger_time"    : event_ts,
            "processing_ts"         : processing_ts,
            "filesize"              : filesize,
            **metrics,

        }

        logger.info(f"File processed successfully with details : {payload}")

        return {
            "statusCode"    : 200,
            "desc"          : "Processing successful",
            "payload"       : json.dumps(payload, default=str)
        }
    
    except Exception as e:
        logger.error("Processing failed: %s", str(e), exc_info=True)
        return {
            "statusCode"    : 500, # server side error
            "desc"          : "Processing Failed",
            "payload"       : json.dumps({"error": str(e)})
        }





    