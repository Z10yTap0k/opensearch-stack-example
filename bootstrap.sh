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

# Канал создаётся с предсказуемым ID: повторный запуск bootstrap обновляет URL,
# а не создаёт ещё один channel.
NOTIFICATION_CONFIG_ID="local-webhook"
NOTIFICATION_CONFIG_URL="$OPENSEARCH_URL/_plugins/_notifications/configs/$NOTIFICATION_CONFIG_ID"
NOTIFICATION_CONFIG_PAYLOAD='/tmp/local-webhook-notification.json'
cat > "$NOTIFICATION_CONFIG_PAYLOAD" <<'EOF'
{
  "config": {
    "name": "Local webhook receiver",
    "description": "Receives OpenSearch custom-webhook notifications in Docker Compose logs",
    "config_type": "webhook",
    "is_enabled": true,
    "webhook": {
      "url": "http://notification-webhook:8080/notifications",
      "method": "POST",
      "header_params": {
        "Content-Type": "application/json"
      }
    }
  }
}
EOF

echo "Создание notification channel ${NOTIFICATION_CONFIG_ID}..."
notification_metadata="/tmp/${NOTIFICATION_CONFIG_ID}.metadata"
if notification_status=$(curl -sS -o "$notification_metadata" -w '%{http_code}' \
  -X GET -k -u "$AUTH" "$NOTIFICATION_CONFIG_URL"); then
  case "$notification_status" in
    200)
      notification_method="PUT"
      notification_payload="$NOTIFICATION_CONFIG_PAYLOAD"
      echo "Notification channel ${NOTIFICATION_CONFIG_ID} уже существует; выполняется обновление."
      ;;
    404)
      notification_method="POST"
      notification_payload="/tmp/${NOTIFICATION_CONFIG_ID}.create.json"
      jq --arg config_id "$NOTIFICATION_CONFIG_ID" --arg name "$NOTIFICATION_CONFIG_ID" \
        '. + {config_id: $config_id, name: $name}' \
        "$NOTIFICATION_CONFIG_PAYLOAD" > "$notification_payload"
      echo "Notification channel ${NOTIFICATION_CONFIG_ID} не найден; выполняется создание."
      ;;
    *)
      echo "Не удалось получить notification channel ${NOTIFICATION_CONFIG_ID}. HTTP status: ${notification_status}" >&2
      cat "$notification_metadata" >&2
      exit 1
      ;;
  esac
else
  curl_status=$?
  echo "Сетевая ошибка при получении notification channel ${NOTIFICATION_CONFIG_ID} (curl exit code ${curl_status})." >&2
  exit "$curl_status"
fi
rm -f "$notification_metadata"

if [ "$notification_method" = "PUT" ]; then
  notification_request_url="$NOTIFICATION_CONFIG_URL"
else
  notification_request_url="$OPENSEARCH_URL/_plugins/_notifications/configs"
fi

if ! notification_status=$(curl -sS -o /tmp/${NOTIFICATION_CONFIG_ID}.response -w '%{http_code}' \
  -X "$notification_method" -k -u "$AUTH" \
  -H "Content-Type: application/json" \
  "$notification_request_url" \
  --data-binary "@$notification_payload"); then
  curl_status=$?
  echo "Сетевая ошибка при сохранении notification channel ${NOTIFICATION_CONFIG_ID} (curl exit code ${curl_status})." >&2
  exit "$curl_status"
fi

case "$notification_status" in
  2??) echo "Notification channel ${NOTIFICATION_CONFIG_ID} сохранён (HTTP ${notification_status})." ;;
  *)
    echo "Не удалось сохранить notification channel ${NOTIFICATION_CONFIG_ID}. HTTP status: ${notification_status}" >&2
    cat /tmp/${NOTIFICATION_CONFIG_ID}.response >&2
    echo "Отправленный JSON:" >&2
    cat "$notification_payload" >&2
    exit 1
    ;;
esac
rm -f "$NOTIFICATION_CONFIG_PAYLOAD" "/tmp/${NOTIFICATION_CONFIG_ID}.create.json" "/tmp/${NOTIFICATION_CONFIG_ID}.response"

# Query-level monitors считают документы за интервал запуска (одну минуту).
# Мониторы не имеют задаваемого client-side ID, поэтому bootstrap ищет их по
# уникальному имени и обновляет с текущими seq_no/primary_term.
ALERTING_MONITORS_URL="$OPENSEARCH_URL/_plugins/_alerting/monitors"

upsert_log_rate_monitor() {
  monitor_name="$1"
  monitor_payload="$2"
  monitor_search_file="/tmp/$(echo "$monitor_name" | tr ' ' '-').search.json"
  monitor_search_response_file="/tmp/$(echo "$monitor_name" | tr ' ' '-').monitors.json"

  jq -n --arg name "$monitor_name" '{size: 10, query: {match: {"monitor.name": $name}}}' > "$monitor_search_file"

  echo "Настройка alert monitor ${monitor_name}..."
  if monitor_status=$(curl -sS -o "$monitor_search_response_file" -w '%{http_code}' \
    -X POST -k -u "$AUTH" -H "Content-Type: application/json" \
    "$ALERTING_MONITORS_URL/_search" --data-binary "@$monitor_search_file"); then
    :
  else
    curl_status=$?
    echo "Сетевая ошибка при поиске alert monitor ${monitor_name} (curl exit code ${curl_status})." >&2
    exit "$curl_status"
  fi
  rm -f "$monitor_search_file"
  if [ "$monitor_status" != "200" ]; then
    echo "Не удалось найти alert monitor ${monitor_name}. HTTP status: ${monitor_status}" >&2
    cat "$monitor_search_response_file" >&2
    exit 1
  fi

  monitor_id=$(jq -er --arg name "$monitor_name" '
    [.hits.hits[]? | select(._source.name == $name) | ._id]
    | if length == 0 then "" elif length == 1 then .[0] else error("duplicate monitor name") end
  ' "$monitor_search_response_file")
  rm -f "$monitor_search_response_file"

  if [ -n "$monitor_id" ]; then
    monitor_metadata_file="/tmp/${monitor_id}.metadata.json"
    if monitor_status=$(curl -sS -o "$monitor_metadata_file" -w '%{http_code}' \
      -X GET -k -u "$AUTH" "$ALERTING_MONITORS_URL/$monitor_id"); then
      :
    else
      curl_status=$?
      echo "Сетевая ошибка при получении alert monitor ${monitor_name} (curl exit code ${curl_status})." >&2
      exit "$curl_status"
    fi
    if [ "$monitor_status" != "200" ]; then
      echo "Не удалось получить alert monitor ${monitor_name}. HTTP status: ${monitor_status}" >&2
      cat "$monitor_metadata_file" >&2
      exit 1
    fi
    monitor_seq_no=$(jq -er '._seq_no' "$monitor_metadata_file")
    monitor_primary_term=$(jq -er '._primary_term' "$monitor_metadata_file")
    rm -f "$monitor_metadata_file"
    monitor_method="PUT"
    monitor_url="$ALERTING_MONITORS_URL/$monitor_id?if_seq_no=$monitor_seq_no&if_primary_term=$monitor_primary_term"
    echo "Alert monitor ${monitor_name} уже существует; выполняется обновление."
  else
    monitor_method="POST"
    monitor_url="$ALERTING_MONITORS_URL"
    echo "Alert monitor ${monitor_name} не найден; выполняется создание."
  fi

  monitor_response_file="/tmp/$(echo "$monitor_name" | tr ' ' '-').response.json"
  if monitor_status=$(curl -sS -o "$monitor_response_file" -w '%{http_code}' \
    -X "$monitor_method" -k -u "$AUTH" \
    -H "Content-Type: application/json" \
    "$monitor_url" --data-binary "@$monitor_payload"); then
    :
  else
    curl_status=$?
    echo "Сетевая ошибка при сохранении alert monitor ${monitor_name} (curl exit code ${curl_status})." >&2
    exit "$curl_status"
  fi
  case "$monitor_status" in
    2??) echo "Alert monitor ${monitor_name} сохранён (HTTP ${monitor_status})." ;;
    *)
      echo "Не удалось сохранить alert monitor ${monitor_name}. HTTP status: ${monitor_status}" >&2
      cat "$monitor_response_file" >&2
      echo "Отправленный JSON:" >&2
      cat "$monitor_payload" >&2
      exit 1
      ;;
  esac
  rm -f "$monitor_response_file"
}

upsert_log_rate_monitor "Dev team log rate above 10 per minute" /monitors/dev-log-rate.json
upsert_log_rate_monitor "Prod team log rate above 10 per minute" /monitors/prod-log-rate.json

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

# The Data Prepper OpenSearch sink verifies its target by creating an index.
# A composable template with "data_stream": {} rejects that operation, so
# create the named streams explicitly after their templates have been loaded.
for data_stream in dev-app-server dev-app-client prod-app-server prod-app-client; do
  data_stream_url="$OPENSEARCH_URL/_data_stream/$data_stream"
  metadata_file="/tmp/opensearch-data-stream-${data_stream}.metadata"

  if existing_status=$(curl -sS -o "$metadata_file" -w '%{http_code}' \
    -X GET -k -u "$AUTH" "$data_stream_url"); then
    case "$existing_status" in
      200)
        echo "Data stream ${data_stream} уже существует."
        ;;
      404)
        echo "Создание data stream ${data_stream}..."
        if create_status=$(curl -sS -o "$metadata_file" -w '%{http_code}' \
          -X PUT -k -u "$AUTH" "$data_stream_url"); then
          case "$create_status" in
            2??) echo "Data stream ${data_stream} создан (HTTP ${create_status})." ;;
            *)
              echo "Не удалось создать data stream ${data_stream} (HTTP ${create_status})." >&2
              cat "$metadata_file" >&2
              rm -f "$metadata_file"
              exit 1
              ;;
          esac
        else
          echo "Сетевая ошибка при создании data stream ${data_stream}." >&2
          rm -f "$metadata_file"
          exit 1
        fi
        ;;
      *)
        echo "Не удалось проверить data stream ${data_stream} (HTTP ${existing_status})." >&2
        cat "$metadata_file" >&2
        rm -f "$metadata_file"
        exit 1
        ;;
    esac
  else
    echo "Сетевая ошибка при проверке data stream ${data_stream}." >&2
    rm -f "$metadata_file"
    exit 1
  fi

  rm -f "$metadata_file"
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
    log_index_permissions='"dev-app-server", ".ds-dev-app-server-*", "dev-app-client", ".ds-dev-app-client-*"'
  else
    log_index_permissions='"prod-app-server", ".ds-prod-app-server-*", "prod-app-client", ".ds-prod-app-client-*", "prod-docker", ".ds-prod-docker-*"'
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

echo "Creating dev tenant application logs data view..."
curl -sS -k \
  -u "$AUTH" \
  -H "osd-xsrf: true" \
  -H "securitytenant: dev_team" \
  -H "Content-Type: application/json" \
  -X POST \
  "$DASH_URL/api/saved_objects/index-pattern/dev-app-logs" \
  -d '{
    "attributes": {
      "title": "dev-app-*",
      "timeFieldName": "@timestamp"
    }
  }' || true

echo "Creating prod tenant application logs data view..."
curl -sS -k \
  -u "$AUTH" \
  -H "osd-xsrf: true" \
  -H "securitytenant: prod_team" \
  -H "Content-Type: application/json" \
  -X POST \
  "$DASH_URL/api/saved_objects/index-pattern/prod-app-logs" \
  -d '{
    "attributes": {
      "title": "prod-app-*",
      "timeFieldName": "@timestamp"
    }
  }' || true

echo "Инициализация OpenSearch успешно завершена!"
