"""
Shared SQS client wrapper.
All services use this to publish and consume messages.
Set AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY in env.
"""
import os
import json
import boto3
from typing import Callable

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")


def get_sqs_client():
    return boto3.client(
        "sqs",
        region_name=AWS_REGION,
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID"),
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
    )


def publish(queue_url: str, event_type: str, payload: dict) -> None:
    """Publish a message to an SQS queue."""
    client = get_sqs_client()
    body = json.dumps({"event_type": event_type, "payload": payload})
    client.send_message(QueueUrl=queue_url, MessageBody=body)


def consume(queue_url: str, handler: Callable[[str, dict], None], max_messages: int = 10) -> None:
    """
    Poll SQS for messages and call handler(event_type, payload) for each.
    Deletes message after successful handling.
    """
    client = get_sqs_client()
    response = client.receive_message(
        QueueUrl=queue_url,
        MaxNumberOfMessages=max_messages,
        WaitTimeSeconds=10,  # long polling
    )
    for msg in response.get("Messages", []):
        body = json.loads(msg["Body"])
        handler(body["event_type"], body["payload"])
        client.delete_message(QueueUrl=queue_url, ReceiptHandle=msg["ReceiptHandle"])
