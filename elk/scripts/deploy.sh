#!/usr/bin/env bash
# Runs ON the ELK EC2 instance as root (Jenkins starts it through AWS Systems Manager).
# Safe to run again: it updates the stack in place.
#
# Required environment:
#   ELK_SECRET_ID  Secrets Manager secret with the passwords (created by the infra repo)
#   AWS_REGION     region of the secret
# For a local test without AWS, leave ELK_SECRET_ID empty and export the five password variables instead.
set -euo pipefail

cd "$(dirname "$0")/.."

# Non-secret settings (version, heap sizes, retention, data directory)
set -a
# shellcheck disable=SC1091
source ./elk.env
set +a

if [ -n "${ELK_SECRET_ID:-}" ]; then
  echo "Reading passwords from Secrets Manager: ${ELK_SECRET_ID}"
  SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$ELK_SECRET_ID" \
    --region "${AWS_REGION:?AWS_REGION is required}" --query SecretString --output text)
  ELASTIC_PASSWORD=$(echo "$SECRET_JSON" | jq -r .elastic_password)
  KIBANA_SYSTEM_PASSWORD=$(echo "$SECRET_JSON" | jq -r .kibana_system_password)
  LOGSTASH_WRITER_PASSWORD=$(echo "$SECRET_JSON" | jq -r .logstash_writer_password)
  METRICBEAT_WRITER_PASSWORD=$(echo "$SECRET_JSON" | jq -r .metricbeat_writer_password)
  KIBANA_ENCRYPTION_KEY=$(echo "$SECRET_JSON" | jq -r .kibana_encryption_key)
fi

: "${ELASTIC_PASSWORD:?missing}" "${KIBANA_SYSTEM_PASSWORD:?missing}" "${LOGSTASH_WRITER_PASSWORD:?missing}"
: "${METRICBEAT_WRITER_PASSWORD:?missing}" "${KIBANA_ENCRYPTION_KEY:?missing}"

# .env is read by docker compose and setup.sh; only root can read it
umask 077
cat > .env <<EOF
ELASTIC_VERSION=${ELASTIC_VERSION}
ENVIRONMENT=${ENVIRONMENT}
DATA_DIR=${DATA_DIR}
ES_HEAP=${ES_HEAP}
LS_HEAP=${LS_HEAP}
LOGS_RETENTION_DAYS=${LOGS_RETENTION_DAYS}
METRICS_RETENTION_DAYS=${METRICS_RETENTION_DAYS}
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
KIBANA_SYSTEM_PASSWORD=${KIBANA_SYSTEM_PASSWORD}
LOGSTASH_WRITER_PASSWORD=${LOGSTASH_WRITER_PASSWORD}
METRICBEAT_WRITER_PASSWORD=${METRICBEAT_WRITER_PASSWORD}
KIBANA_ENCRYPTION_KEY=${KIBANA_ENCRYPTION_KEY}
EOF
umask 022

# Elasticsearch runs as uid 1000 inside the container
mkdir -p "${DATA_DIR}/elasticsearch"
chown -R 1000:0 "${DATA_DIR}/elasticsearch"

echo "Starting Elasticsearch, Logstash and Kibana ${ELASTIC_VERSION}"
docker compose pull --quiet
docker compose up -d --remove-orphans

./scripts/setup.sh

docker compose ps
echo "ELK deploy finished"
