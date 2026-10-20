#!/usr/bin/env bash
# Elasticsearch and Kibana setup, called by deploy.sh. Every step is idempotent.
#   1. kibana_system password
#   2. Roles and users for Logstash and Metricbeat (least privilege, no superuser in the shippers)
#   3. Log retention (ILM policy applied to all logs-*-* data streams)
#   4. Metricbeat index template, dashboards and retention
#   5. Kibana data views for the logs
set -euo pipefail

cd "$(dirname "$0")/.."

set -a
# shellcheck disable=SC1091
source ./.env
set +a

ES="http://localhost:9200"
KB="http://localhost:5601"

# Call the Elasticsearch API as the elastic superuser: es METHOD PATH [JSON]
es() {
  local args=(-sS -f -u "elastic:${ELASTIC_PASSWORD}" -X "$1" "${ES}$2" -H "Content-Type: application/json")
  if [ -n "${3:-}" ]; then args+=(-d "$3"); fi
  curl "${args[@]}"
  echo
}

# Call the Kibana API: kb METHOD PATH [JSON]
kb() {
  local args=(-sS -f -u "elastic:${ELASTIC_PASSWORD}" -X "$1" "${KB}$2" -H "Content-Type: application/json" -H "kbn-xsrf: true")
  if [ -n "${3:-}" ]; then args+=(-d "$3"); fi
  curl "${args[@]}" -o /dev/null -w "HTTP %{http_code}\n"
}

wait_for() {
  local name=$1 check=$2
  echo "Waiting for ${name}..."
  for _ in $(seq 1 120); do
    if eval "$check" >/dev/null 2>&1; then echo "${name} is ready"; return 0; fi
    sleep 5
  done
  echo "${name} did not become ready in 10 minutes" >&2
  return 1
}

wait_for "Elasticsearch" \
  "curl -s -u 'elastic:${ELASTIC_PASSWORD}' ${ES}/_cluster/health | grep -qE '\"status\":\"(green|yellow)\"'"

echo "== 1. kibana_system password"
es POST /_security/user/kibana_system/_password "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}"

echo "== 2. Roles and users for the shippers"
es PUT /_security/role/logstash_writer '{
  "cluster": ["monitor", "manage_ilm", "manage_index_templates"],
  "indices": [{ "names": ["logs-*"], "privileges": ["create_doc", "create_index", "auto_configure", "view_index_metadata"] }]
}'
es PUT /_security/user/logstash_writer "{\"password\":\"${LOGSTASH_WRITER_PASSWORD}\",\"roles\":[\"logstash_writer\"],\"full_name\":\"Logstash writer\"}"

es PUT /_security/role/metricbeat_writer '{
  "cluster": ["monitor", "read_ilm", "read_pipeline"],
  "indices": [{ "names": ["metricbeat-*"], "privileges": ["create_doc", "view_index_metadata", "auto_configure"] }]
}'
es PUT /_security/user/metricbeat_writer "{\"password\":\"${METRICBEAT_WRITER_PASSWORD}\",\"roles\":[\"metricbeat_writer\"],\"full_name\":\"Metricbeat writer\"}"

echo "== 3. Log retention: ${LOGS_RETENTION_DAYS} days"
es PUT /_ilm/policy/hr-logs "{
  \"policy\": { \"phases\": {
    \"hot\":    { \"actions\": { \"rollover\": { \"max_age\": \"1d\", \"max_primary_shard_size\": \"10gb\" } } },
    \"delete\": { \"min_age\": \"${LOGS_RETENTION_DAYS}d\", \"actions\": { \"delete\": {} } }
  } }
}"
# logs@custom is part of the built-in logs-*-* template: every logs data stream uses this policy.
# Single Elasticsearch node, so no replicas.
es PUT /_component_template/logs@custom '{
  "template": { "settings": { "index.lifecycle.name": "hr-logs", "index.number_of_replicas": 0 } }
}'

wait_for "Kibana" \
  "curl -s -u 'elastic:${ELASTIC_PASSWORD}' ${KB}/api/status | grep -q '\"level\":\"available\"'"

echo "== 4. Metricbeat index template, ILM policy and dashboards"
docker run --rm --network elk_default "docker.elastic.co/beats/metricbeat:${ELASTIC_VERSION}" \
  setup --index-management --dashboards \
  -E 'output.elasticsearch.hosts=["http://elasticsearch:9200"]' \
  -E output.elasticsearch.username=elastic \
  -E "output.elasticsearch.password=${ELASTIC_PASSWORD}" \
  -E setup.kibana.host=http://kibana:5601 \
  -E setup.template.settings.index.number_of_replicas=0

echo "== Metric retention: ${METRICS_RETENTION_DAYS} days"
es PUT /_ilm/policy/metricbeat "{
  \"policy\": { \"phases\": {
    \"hot\":    { \"actions\": { \"rollover\": { \"max_age\": \"1d\", \"max_primary_shard_size\": \"10gb\" } } },
    \"delete\": { \"min_age\": \"${METRICS_RETENTION_DAYS}d\", \"actions\": { \"delete\": {} } }
  } }
}"

echo "== 5. Kibana data views"
kb POST /api/data_views/data_view '{
  "data_view": { "id": "hr-portal-app-logs", "title": "logs-hr_portal-*", "name": "HR Portal application logs", "timeFieldName": "@timestamp" },
  "override": true
}'
kb POST /api/data_views/data_view '{
  "data_view": { "id": "all-container-logs", "title": "logs-*", "name": "All container logs", "timeFieldName": "@timestamp" },
  "override": true
}'

echo "Setup complete"
