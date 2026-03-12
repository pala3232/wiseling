#!/bin/bash
SECRET=$(openssl rand -hex 32)
if [ -z "$SECRET" ]; then
  echo "Failed to generate secret!"
  exit 1
fi
if ! command -v aws &> /dev/null; then
  echo "AWS CLI not found! Please install it to proceed."
    exit 1
fi

if ! aws secretsmanager update-secret --secret-id wiseling-jwt-secret-key --secret-string "$SECRET" --region ap-southeast-2; then
  echo "Failed to update secret!"
  exit 1
fi

echo "Updated secret!"