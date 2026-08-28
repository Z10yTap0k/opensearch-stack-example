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

echo "Ожидание OIDC discovery Keycloak..."
until curl -fsS \
  "http://keycloak.lvh.me:8080/realms/opensearch/.well-known/openid-configuration" \
  | grep -q '"issuer"'; do
    sleep 2
done

# Локальный стенд включает возможность менять Security config через REST API.
# Не заменяем существующий basic domain: OIDC добавляется как второй auth domain.
if curl -s -k -u "$AUTH" \
  "$OPENSEARCH_URL/_plugins/_security/api/securityconfig" \
  | grep -q '"oidc_auth_domain"'; then
    echo "OIDC auth domain уже настроен."
else
    echo "Добавление OIDC auth domain..."
    curl -fsS -X PATCH -k -u "$AUTH" \
      -H "Content-Type: application/json" \
      "$OPENSEARCH_URL/_plugins/_security/api/securityconfig" \
      -d '[
        {
          "op": "add",
          "path": "/config/dynamic/authc/oidc_auth_domain",
          "value": {
            "http_enabled": true,
            "transport_enabled": false,
            "order": 1,
            "http_authenticator": {
              "type": "openid",
              "challenge": false,
              "config": {
                "subject_key": "preferred_username",
                "roles_key": "roles",
                "openid_connect_url": "http://keycloak.lvh.me:8080/realms/opensearch/.well-known/openid-configuration",
                "required_audience": "opensearch-dashboards"
              }
            },
            "authentication_backend": {
              "type": "noop",
              "config": {}
            }
          }
        }
      ]'
fi

echo "Загрузка OpenSearch templates..."
for template_file in /templates/*.json; do
  template_name=$(basename "$template_file" .json)
  response_file="/tmp/opensearch-template-${template_name}.response"
  headers_file="/tmp/opensearch-template-${template_name}.headers"

  echo "Загрузка шаблона ${template_name}..."
  if http_status=$(curl -sS -D "$headers_file" -o "$response_file" -w '%{http_code}' \
    -X PUT -k -u "$AUTH" \
    -H "Content-Type: application/json" \
    "$OPENSEARCH_URL/_index_template/$template_name" \
    --data-binary "@$template_file"); then
    case "$http_status" in
      2??)
        echo "Шаблон ${template_name} загружен (HTTP ${http_status})."
        rm -f "$response_file"
        rm -f "$headers_file"
        ;;
      *)
        echo "Не удалось загрузить шаблон ${template_name}." >&2
        echo "Файл шаблона: ${template_file}" >&2
        echo "URL: $OPENSEARCH_URL/_index_template/$template_name" >&2
        echo "HTTP status: ${http_status}" >&2
        echo "HTTP headers:" >&2
        cat "$headers_file" >&2
        if [ -s "$response_file" ]; then
          echo "Ответ OpenSearch:" >&2
          cat "$response_file" >&2
        else
          echo "Ответ OpenSearch: <пустой>" >&2
        fi
        echo "Отправленный JSON:" >&2
        cat "$template_file" >&2
        rm -f "$response_file" "$headers_file"
        exit 1
        ;;
    esac
  else
    curl_status=$?
    echo "Сетевая ошибка при загрузке шаблона ${template_name} (curl exit code ${curl_status})." >&2
    echo "Файл шаблона: ${template_file}" >&2
    echo "URL: $OPENSEARCH_URL/_index_template/$template_name" >&2
    if [ -s "$headers_file" ]; then
      echo "Полученные HTTP headers:" >&2
      cat "$headers_file" >&2
    fi
    if [ -s "$response_file" ]; then
      echo "Ответ OpenSearch:" >&2
      cat "$response_file" >&2
    fi
    rm -f "$response_file" "$headers_file"
    exit "$curl_status"
  fi
done

echo "Загрузка ISM policies..."
for policy_file in /policies/*.json; do
  # В пустой папке glob остаётся строкой '/policies/*.json'.
  [ -f "$policy_file" ] || continue

  policy_name=$(basename "$policy_file" .json)
  response_file="/tmp/opensearch-ism-policy-${policy_name}.response"
  headers_file="/tmp/opensearch-ism-policy-${policy_name}.headers"
  metadata_file="/tmp/opensearch-ism-policy-${policy_name}.metadata"
  policy_url="$OPENSEARCH_URL/_plugins/_ism/policies/$policy_name"

  echo "Загрузка ISM policy ${policy_name}..."
  if existing_status=$(curl -sS -o "$metadata_file" -w '%{http_code}' \
    -X GET -k -u "$AUTH" "$policy_url"); then
    case "$existing_status" in
      200)
        policy_seq_no=$(jq -er '._seq_no' "$metadata_file")
        policy_primary_term=$(jq -er '._primary_term' "$metadata_file")
        policy_url="${policy_url}?if_seq_no=${policy_seq_no}&if_primary_term=${policy_primary_term}"
        echo "ISM policy ${policy_name} уже существует; выполняется обновление."
        ;;
      404)
        echo "ISM policy ${policy_name} не найдена; выполняется создание."
        ;;
      *)
        echo "Не удалось получить ISM policy ${policy_name} перед загрузкой." >&2
        echo "URL: ${policy_url}" >&2
        echo "HTTP status: ${existing_status}" >&2
        echo "Ответ OpenSearch:" >&2
        if [ -s "$metadata_file" ]; then
          cat "$metadata_file" >&2
        else
          echo "<пустой>" >&2
        fi
        rm -f "$response_file" "$headers_file" "$metadata_file"
        exit 1
        ;;
    esac
  else
    curl_status=$?
    echo "Сетевая ошибка при получении ISM policy ${policy_name} (curl exit code ${curl_status})." >&2
    echo "URL: ${policy_url}" >&2
    rm -f "$response_file" "$headers_file" "$metadata_file"
    exit "$curl_status"
  fi
  rm -f "$metadata_file"

  if http_status=$(curl -sS -D "$headers_file" -o "$response_file" -w '%{http_code}' \
    -X PUT -k -u "$AUTH" \
    -H "Content-Type: application/json" \
    "$policy_url" \
    --data-binary "@$policy_file"); then
    case "$http_status" in
      2??)
        echo "ISM policy ${policy_name} загружена (HTTP ${http_status})."
        rm -f "$response_file" "$headers_file"
        ;;
      *)
        echo "Не удалось загрузить ISM policy ${policy_name}." >&2
        echo "Файл policy: ${policy_file}" >&2
        echo "URL: ${policy_url}" >&2
        echo "HTTP status: ${http_status}" >&2
        echo "HTTP headers:" >&2
        cat "$headers_file" >&2
        if [ -s "$response_file" ]; then
          echo "Ответ OpenSearch:" >&2
          cat "$response_file" >&2
        else
          echo "Ответ OpenSearch: <пустой>" >&2
        fi
        echo "Отправленный JSON:" >&2
        cat "$policy_file" >&2
        rm -f "$response_file" "$headers_file"
        exit 1
        ;;
    esac
  else
    curl_status=$?
    echo "Сетевая ошибка при загрузке ISM policy ${policy_name} (curl exit code ${curl_status})." >&2
    echo "Файл policy: ${policy_file}" >&2
    echo "URL: ${policy_url}" >&2
    if [ -s "$headers_file" ]; then
      echo "Полученные HTTP headers:" >&2
      cat "$headers_file" >&2
    fi
    if [ -s "$response_file" ]; then
      echo "Ответ OpenSearch:" >&2
      cat "$response_file" >&2
    fi
    rm -f "$response_file" "$headers_file"
    exit "$curl_status"
  fi
done

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

# Каждому backend role Keycloak соответствует отдельная роль OpenSearch и tenant.
# Telemetry indexes общие для демонстрационного стенда, объекты Dashboards изолированы tenant-ами.
for team in dev prod; do
  tenant="${team}_team"
  role="${tenant}_user"

  if [ "$team" = "dev" ]; then
    log_index_permissions='"dev-app-client", ".ds-dev-app-client-*"'
  else
    log_index_permissions='"prod-app-server", ".ds-prod-app-server-*", "prod-docker", ".ds-prod-docker-*"'
  fi

  echo "Создание роли ${role}..."
  curl -fsS -X PUT -k -u "$AUTH" \
    -H "Content-Type: application/json" \
    "$OPENSEARCH_URL/_plugins/_security/api/roles/$role" \
    -d "{
      \"cluster_permissions\": [\"cluster_composite_ops_ro\", \"cluster:monitor/main\"],
      \"index_permissions\": [
        {
          \"index_patterns\": [\"ss4o*\", \"otel-*\", $log_index_permissions],
          \"allowed_actions\": [\"read\"]
        }
      ],
      \"tenant_permissions\": [
        {
          \"tenant_patterns\": [\"$tenant\"],
          \"allowed_actions\": [\"kibana_all_write\"]
        }
      ]
    }"

  echo "Связывание Keycloak role ${tenant} с ${role}..."
  curl -fsS -X PUT -k -u "$AUTH" \
    -H "Content-Type: application/json" \
    "$OPENSEARCH_URL/_plugins/_security/api/rolesmapping/$role" \
    -d "{\"backend_roles\": [\"$tenant\"]}"
done

# 5. Регистрация репозитория хранения снэпшотов в S3 (SeaweedFS)
echo "Регистрация репозитория S3 Snapshots..."
curl -X PUT -k -u "$AUTH" \
  -H "Content-Type: application/json" \
  "$OPENSEARCH_URL/_snapshot/my_s3_repository" \
  -d '{
    "type": "s3",
    "settings": {
      "bucket": "opensearch-snapshots",
      "region": "us-east-1",
      "endpoint": "http://seaweedfs:8333",
      "protocol": "http",
      "path_style_access": true
    }
  }'

echo "Creating Prometheus datasource..."

echo "Ожидание готовности OpenSearch Dashboards..."
until curl -sS -u "$AUTH" "$DASH_URL/api/status" | grep -q '"overall"'; do
    sleep 2
done

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

# echo "Creating SS4O metrics data view..."
# curl -sS -k \
#   -u "$AUTH" \
#   -H "osd-xsrf: true" \
#   -H "Content-Type: application/json" \
#   -X POST \
#   "$DASH_URL/api/saved_objects/index-pattern/ss4o-metrics" \
#   -d '{
#     "attributes": {
#       "title": "ss4o_metrics-otel-*",
#       "timeFieldName": "@timestamp"
#     }
#   }' || true

echo "Creating dev tenant Docker logs data view..."
curl -sS -k \
  -u "$AUTH" \
  -H "osd-xsrf: true" \
  -H "securitytenant: dev_team" \
  -H "Content-Type: application/json" \
  -X POST \
  "$DASH_URL/api/saved_objects/index-pattern/dev-app-client-logs" \
  -d '{
    "attributes": {
      "title": "dev-app-client",
      "timeFieldName": "@timestamp"
    }
  }' || true

echo "Creating prod tenant Docker logs data view..."
curl -sS -k \
  -u "$AUTH" \
  -H "osd-xsrf: true" \
  -H "securitytenant: prod_team" \
  -H "Content-Type: application/json" \
  -X POST \
  "$DASH_URL/api/saved_objects/index-pattern/prod-docker-logs" \
  -d '{
    "attributes": {
      "title": "prod-*",
      "timeFieldName": "@timestamp"
    }
  }' || true

echo "Инициализация OpenSearch успешно завершена!"
