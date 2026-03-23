import json
import io
import os
import logging
from datetime import datetime, timezone
import boto3
import pandas as pd

logger = logging.getLogger()
logger.setLevel(logging.INFO)

S3_CLIENT = boto3.client("s3")
LAMBDA_CLIENT = boto3.client("lambda")
MAX_ROWS_PREVIEW = 5
WORKER_TARGET_BUCKET=os.environ["WORKER_TARGET_BUCKET"]
ALLOWED_EXTENSIONS = {".csv"}

def read_csv_s3( bucketName: str, bucketKey: str) ->io.BytesIO:
    logger.info(f"Trying to read file at s3://{bucketName}/{bucketKey}")
    extension = "." + bucketKey.rsplit('.',1)[-1] if "." in bucketKey else ""
    if extension not in ALLOWED_EXTENSIONS:
        raise Exception(f"UnSupportedFileFormat Error ! Expected: {ALLOWED_EXTENSIONS} | Actual: {extension}")
    obj = S3_CLIENT.get_object(
        Bucket= bucketName,
        Key= bucketKey
    )
    raw = obj["Body"].read()
    logger.info(f"Reading file s3://{bucketName}/{bucketKey} successful with {len(raw)} bytes" )
    return io.BytesIO(raw)

def process_data(objcontent: io.BytesIO, s3file: str)->pd.DataFrame:
    logger.info(f"Processing file at {s3file}")
    sales_df = pd.read_csv(objcontent, header=0)
    sales_valid_df = sales_df[(sales_df["Quantity"] > 0) | (sales_df["Unit_price"] > 0)]
    sales_valid_df["total_amount"] = sales_valid_df["Quantity"] * sales_valid_df["Unit_price"]
    category_conditions = [
        (sales_valid_df["Rating"] > 7, 'High'),
        (sales_valid_df["Rating"] >= 5, 'Medium'),
        (sales_valid_df["Rating"] < 5, 'Low')
    ]
    sales_valid_df["Rating_category"] = sales_valid_df["Rating"].case_when(category_conditions)
    logger.info(f"File Processed Successfully {s3file}. Actual Records: {sales_df.shape[0]} | Output Records: {sales_valid_df.shape[0]} ")
    return sales_valid_df

def lambda_handler(event, context):
    try:
        logger.info(f"Received event from [Orchestrator] worker : {event}")
        callback_id= event["callback_id"]
        bucketName = event["event"]["bucketName"]
        bucketKeys = event["event"]["bucketKeys"]
        output = []
        for bucketKey in bucketKeys:
            filestream = read_csv_s3(bucketName, bucketKey)
            processed_df = process_data(filestream, f"s3//{bucketName}/{bucketKey}")
            csvbuffer = io.BytesIO()
            processed_df.to_csv(csvbuffer, index=False)
            filekey= f"sales_processed_{datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")}.csv"
            S3_CLIENT.put_object(
                Bucket = WORKER_TARGET_BUCKET,
                Key= filekey,
                Body=csvbuffer.getvalue()
            )
            output.append(f"s3://{WORKER_TARGET_BUCKET}/{filekey}")
            logger.info(f"File Successfully processed at s3://{WORKER_TARGET_BUCKET}/{filekey} ")
        
        logger.info("Waking up Orchestrator with success callback")
        LAMBDA_CLIENT.send_durable_execution_callback_success(
            CallbackId= callback_id,
            Result = json.dumps(output, default=str)
        )        

    except Exception as e:
        logger.error("Exception occured!:  %s", str(e), exc_info=True)
        logger.info("Waking up Orchestrator with failure callback")
        LAMBDA_CLIENT.send_durable_execution_callback_failure(
            CallbackId= callback_id,
            Error = {
                'ErrorMessage': 'Failed',
                'StackTrace': [str(e)]
            }
        )
        







