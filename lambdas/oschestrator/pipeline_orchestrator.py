"""
DURABLE LAMBDA — Orchestrator
==============================

This is the DURABLE Lambda function. It:
  1. Receives an order
  2. Creates a CALLBACK (gets a unique callback_id)
  3. Kicks off a worker Lambda, passing the callback_id
  4. SLEEPS waiting for the callback (no compute cost!)
  5. Wakes up when the worker sends the callback result
  6. Returns the final result

The key concept:
  - This function uses create_callback() to get a callback_id
  - Then calls callback.result() to PAUSE itself
  - While paused, you pay $0 for compute
  - The worker Lambda does the heavy work
  - When done, the worker calls send_durable_execution_callback_success(CallbackId=callback_id)
  - This function WAKES UP and continues from where it paused
"""

import json
import boto3
from urlib.parse import unquote_plus
from aws_durable_execution_sdk_python import (
    DurableContext,
    StepContext,
    durable_execution,
    durable_step
)
from aws_durable_execution_sdk_python.config import CallbackConfig, Duration


LAMBDA_CLIENT = boto3.client('lambda')


@durable_step
def start_worker(stepContext: StepContext, event: dict, callback_id:str):
    stepContext.logger.info(f"Starting worker node with event : {event}")
    worker_payload = {
        "event": event,
        "callback_id": callback_id
    }
    LAMBDA_CLIENT.invoke(
        FunctionName="data_transformer_worker",
        InvocationType="Event", ## "Event" = async, "RequestResponse" = sync
        Payload=json.dumps(worker_payload)
    )

    stepContext.logger.info("Worker lambda invoked [Async]")
    return {
        "statusCode"    : 200,
        "description"   : "successful"
    }



@durable_execution
def lambda_handler(event, context: DurableContext):
    """
    Simple flow:
      1. Create a callback (get callback_id)
      2. Start the worker Lambda, pass callback_id
      3. SLEEP — wait for worker to send callback (free!)
      4. Get the result and return it
    """
    bucketName = event["Records"][0]["s3"]["bucket"]["name"]
    bucketKeys = [unquote_plus(record["s3"]["object"]["key"]) for record in event["Records"]]
    context.logger.info(f"Fetched event list from s3 bucket : {bucketName} | objects: {bucketKeys}")

    event_payload = {
        "bucketName": bucketName,
        "bucketKeys": bucketKeys
    }

    callback = context.create_callback(
        name = "worker_callback",
        config = CallbackConfig(
           timeout = Duration.from_minutes(10) #max waittime before timeout
        ),
    )

    callback_id = callback.callback_id
    context.logger.info(f"Callback Id created : {callback_id}")

    context.step(
        start_worker(event_payload, callback_id),
        name="start_worker"
    )
    context.logger.info("Worker node started. Now going to sleep ...")

    worker_result = callback.result() # waiting for resutl async and sleeping

    print(f"[Orchestrator] Worker finished! Result : {worker_result}") # during replays context may not flush messages
    context.logger.info(f"[Orchestrator] Worker finished! Result : {worker_result}") 

    return {
        "statusCode": 200,
        "description": "Completed",
        "workerResult": json.dumps(worker_result, default=str)
    }

