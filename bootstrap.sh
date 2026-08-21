#!/bin/sh
set -e

OPENSEARCH_URL="https://opensearch:9200"
DASH_URL="http://opensearch-dashboards:5601"
AUTH="admin:YourSecurePassword123!"

echo "Ожидание готовности OpenSearch..."
until curl -s -k -u "$AUTH" "$OPENSEARCH_URL/_cluster/health" | grep -q '"status"'; do
    sleep 5
done
echo "OpenSearch готов! Начинаем настройку Security API..."

# 1. Создаем тенант: dev_team
echo "Создание тенанта dev_team..."
curl -X PUT -k -u "$AUTH" \
  -H "Content-Type: application/json" \
  "$OPENSEARCH_URL/_plugins/_security/api/tenants/dev_team" \
  -d '{"description": "Development Team Tenant"}'

# 2. Создаем тенант: prod_team
echo "Создание тенанта prod_team..."
curl -X PUT -k -u "$AUTH" \
  -H "Content-Type: application/json" \
  "$OPENSEARCH_URL/_plugins/_security/api/tenants/prod_team" \
  -d '{"description": "Production Team Tenant"}'

# 3. Выкачиваем текущую конфигурацию роли admin
echo "Получение текущих прав роли admin..."
curl -X GET -k -u "$AUTH" "$OPENSEARCH_URL/_plugins/_security/api/roles/admin" > /tmp/admin_role.json

# Формируем JSON для обновления роли admin, явно добавляя новые тенанты в блок tenant_permissions
# Используем встроенный в alpine инструмент sed/cat для сборки чистого JSON payload
cat <<EOF > /tmp/payload.json
{
  "cluster_permissions": [ "cluster_all" ],
  "index_permissions": [ {
    "index_patterns": [ "*" ],
    "allowed_actions": [ "all" ]
  } ],
  "tenant_permissions": [
    {
      "tenant_patterns": [ "global_tenant", "dev_team", "prod_team" ],
      "allowed_actions": [ "kibana_all" ]
    }
  ]
}
EOF

# 4. Обновляем роль admin в OpenSearch Security Plugin
echo "Назначение прав на тенанты для роли admin..."
curl -X PUT -k -u "$AUTH" \
  -H "Content-Type: application/json" \
  "$OPENSEARCH_URL/_plugins/_security/api/roles/admin" \
  -d @/tmp/payload.json

# 5. Регистрация репозитория хранения снэпшотов в S3 (MinIO)
echo "Регистрация репозитория S3 Snapshots..."
curl -X PUT -k -u "$AUTH" \
  -H "Content-Type: application/json" \
  "$OPENSEARCH_URL/_snapshot/my_s3_repository" \
  -d '{
    "type": "s3",
    "settings": {
      "bucket": "opensearch-snapshots",
      "region": "us-east-1",
      "endpoint": "http://minio:9000",
      "protocol": "http",
      "path_style_access": true
    }
  }'

echo "Creating Prometheus datasource..."

curl -sS -k \
  -u "$AUTH" \
  -H "osd-xsrf: true" \
  -H "Content-Type: application/json" \
  -X POST \
  "$DASH_URL/api/saved_objects/datasource/prometheus" \
  -d '{
    "attributes": {
      "title": "Prometheus",
      "description": "",
      "endpoint": "http://prometheus:9090",
      "authenticationType": "none"
    }
  }' || true

echo "Инициализация OpenSearch успешно завершена!"
