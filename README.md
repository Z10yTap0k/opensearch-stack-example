# OpenSearch observability stack

Готовый локальный стенд observability на Docker Compose. Он демонстрирует путь OpenTelemetry-трейсов и метрик от .NET-приложений до OpenSearch, параллельный сбор метрик Prometheus и S3-совместимое хранилище SeaweedFS для логов и snapshot-репозитория OpenSearch.

Это проект для разработки и экспериментов: пароли заданы прямо в конфигурации, TLS OpenSearch использует self-signed сертификат, а порты открыты на `localhost`.

## Что разворачивается

| Сервис | Роль | Данные |
| --- | --- | --- |
| `server` | ASP.NET Core API с OpenTelemetry-инструментацией | Нет persistent-данных |
| `client` | Каждые 30 секунд вызывает API и создаёт трейсы | Нет persistent-данных |
| `otel-collector` | Принимает OTLP по gRPC/HTTP; направляет трейсы и метрики в Data Prepper, а метрики также в Prometheus | Нет persistent-данных |
| `data-prepper` | Преобразует трейсы и OTel-метрики, записывая их в OpenSearch | Нет persistent-данных |
| `vector` | Читает Docker stdout/stderr и записывает контейнерные логи в OpenSearch | `vector-data` |
| `opensearch` | Хранит индексы, включая trace analytics | `opensearch-data` |
| `opensearch-dashboards` | Интерфейс поиска, визуализации и OIDC-входа в OpenSearch | Нет persistent-данных |
| `keycloak` | Локальный OpenID Connect provider; импортирует realm, client и demo-пользователей | Нет persistent-данных (dev mode) |
| `prometheus` | Хранит метрики и опрашивает метрики Collector | `prometheus-data` |
| `seaweedfs` | Одноузловой S3 API и Admin UI; один SeaweedFS volume server | `seaweedfs-data` |
| `opensearch-bootstrap` | Одноразово создаёт tenants, OIDC domain, роли, S3 snapshot repository, ISM policies и Dashboards data sources | Нет persistent-данных |

## Схема данных

```text
demo-client ──HTTP──> demo-server
     │                    │
     └──── OTLP/gRPC ─────┘
                 │
                 v
       OpenTelemetry Collector
          │              │
          │ traces, metrics      │ OTLP logs (если их отправляет клиент)
          v                      v
      Data Prepper           SeaweedFS / otel-archive
          │
          v
      OpenSearch <── OpenSearch Dashboards
          ^
          │ Docker stdout/stderr
        Vector

Prometheus ──scrape──> OpenTelemetry Collector :8889
```

Демо-приложения создают трейсы и метрики автоматически. Метрики поступают одновременно в Prometheus и в SS4O-совместимый индекс OpenSearch `ss4o_metrics-otel-*`. Логовый S3 pipeline готов к приёму OTLP-логов от приложений.

## Требования

- Docker Engine с запущенным daemon;
- Docker Compose v2 (`docker compose version`);
- свободные порты: `5000`, `5601`, `8080`, `9000`, `9090`, `9200`, `23646`, `4317`, `4318`, `8889`, `21893`;
- не менее 4 ГБ памяти, выделенной Docker.

## Быстрый старт

Из корня репозитория:

```bash
docker compose up --build -d
docker compose ps
```

При первом запуске образы и .NET-приложения собираются дольше. Дождитесь завершения одноразовой инициализации:

```bash
docker compose logs --follow opensearch-bootstrap
```

В успешном выводе будет строка `Инициализация OpenSearch успешно завершена!`. Остановить просмотр логов можно `Ctrl+C` — контейнеры продолжат работать.

Проверить API и автоматически генерируемые трейсы:

```bash
curl http://localhost:5000/health
curl "http://localhost:5000/api/test?id=$(uuidgen)"
docker compose logs --tail=100 client
```

Второй запрос создаёт trace `demo-client → demo-server`; клиент выполняет такой же запрос автоматически каждые 30 секунд.

## Интерфейсы, API и порты

| Компонент | Адрес / порт | Как использовать |
| --- | --- | --- |
| OpenSearch Dashboards | [http://localhost:5601](http://localhost:5601) | Войти через Keycloak или под `admin`; открыть Discover или observability. |
| Keycloak Admin Console | [http://keycloak.lvh.me:8080/admin/](http://keycloak.lvh.me:8080/admin/) | Управление локальным IdP, realm `opensearch`, пользователями и ролями. |
| OpenSearch REST API | [https://localhost:9200](https://localhost:9200) | API использует self-signed TLS; для `curl` используйте `-k -u admin:…`. |
| Prometheus | [http://localhost:9090](http://localhost:9090) | Открыть Status → Targets и убедиться, что `otel-collector` в состоянии `UP`; выполнять PromQL-запросы. |
| SeaweedFS Admin UI | [http://localhost:23646](http://localhost:23646) | Просмотр и обслуживание single-node SeaweedFS. Не публикуйте интерфейс наружу без защиты. |
| SeaweedFS S3 API | [http://localhost:9000](http://localhost:9000) | Endpoint для AWS CLI, SDK и S3-клиентов. Это API, не файловый web-интерфейс. |
| Demo API | [http://localhost:5000/health](http://localhost:5000/health) | Проверка доступности приложения; рабочий endpoint: `/api/test?id=<UUID>`. |
| OTLP gRPC | `localhost:4317` | Приём телеметрии от внешних приложений. |
| OTLP HTTP | `http://localhost:4318` | Приём OTLP/HTTP (`/v1/traces`, `/v1/metrics`, `/v1/logs`). |

## Учётные данные и S3

| Сервис | Логин / ключ | Пароль / secret |
| --- | --- | --- |
| OpenSearch и Dashboards | `admin` | `YourSecurePassword123!` |
| Keycloak Admin Console | `keycloak-admin` | `KeycloakAdminPassword123!` |
| Keycloak: development tenant | `dev-user` | `DevUserPassword123!` |
| Keycloak: production tenant | `prod-user` | `ProdUserPassword123!` |
| SeaweedFS S3 | `minioadmin` | `MinioPassword123!` |

## Вход через OpenID Connect и tenants

После `docker compose up --build -d` откройте [OpenSearch Dashboards](http://localhost:5601) и нажмите **«Войти через Keycloak»**. В форме Keycloak используйте одну из demo-учётных записей:

| Пользователь | Роль Keycloak | Доступный tenant в Dashboards |
| --- | --- | --- |
| `dev-user` | `dev_team` | `dev_team` |
| `prod-user` | `prod_team` | `prod_team` |

В JWT Keycloak добавляет роли в claim `roles`. OpenSearch сопоставляет `dev_team` и `prod_team` с ролями `dev_team_user` и `prod_team_user`; каждая роль даёт запись только в свой tenant. В селекторе tenants Dashboards у OIDC-пользователя будет только назначенный custom tenant: Global и Private tenants отключены в UI.

Tenant изолирует сохранённые объекты Dashboards: data views, Discover searches, визуализации и dashboards. Демонстрационные telemetry-индексы (`ss4o_metrics-otel-*` и `otel-*`) намеренно общие и доступны обеим ролям только для чтения. Для изоляции самих данных в реальном окружении создайте отдельные индексы/aliases на tenant либо добавьте document-level security в роли из `bootstrap.sh`.

Basic-вход `admin` сохранён для локального администрирования и автоматизации. У него есть доступ к обоим custom tenants. Изменять пользователей, роли и redirect URI можно в [Keycloak Admin Console](http://keycloak.lvh.me:8080/admin/) в realm `opensearch`. Realm-описание хранится в [keycloak/realm-opensearch.json](keycloak/realm-opensearch.json).

Keycloak использует hostname `keycloak.lvh.me`: `lvh.me` резолвится браузером в `127.0.0.1`. В контейнерах этот hostname направлен через Docker host gateway к опубликованному порту Keycloak.

### Проверка настройки

1. Дождитесь строки `Инициализация OpenSearch успешно завершена!` в логах `opensearch-bootstrap`.
2. Войдите как `dev-user`, создайте, например, dashboard `Dev overview` в tenant `dev_team`.
3. Откройте Dashboards в приватном окне и войдите как `prod-user`: `Dev overview` недоступен, потому что `prod_team` использует отдельный tenant index.
4. Для проверки OIDC discovery откройте [metadata realm](http://keycloak.lvh.me:8080/realms/opensearch/.well-known/openid-configuration).

Если нужно войти basic-пользователем при включённом автоматическом OIDC redirect, откройте Dashboards с `?auto_login=false`. В текущем Compose автоматический redirect не включён, поэтому обе кнопки доступны на экране входа.

SeaweedFS запускается в режиме `mini`: в одном контейнере доступны S3 API, Admin UI и один volume server. Persistent Docker volume называется `seaweedfs-data`. На старте автоматически создаются бакеты:

- `opensearch-snapshots` — snapshot repository `my_s3_repository` для OpenSearch;
- `otel-archive` — назначение OTLP log exporter, префикс `logs/`.

Пример аутентифицированного доступа через AWS CLI:

```bash
export AWS_ACCESS_KEY_ID=minioadmin
export AWS_SECRET_ACCESS_KEY='MinioPassword123!'
aws --endpoint-url http://localhost:9000 s3 ls
```

Внутри Docker-сети endpoint отличается: `http://seaweedfs:8333`.

## Работа с OpenSearch

Проверить, что Bootstrap зарегистрировал S3 repository:

```bash
curl -k -u 'admin:YourSecurePassword123!' \
  https://localhost:9200/_snapshot/my_s3_repository?pretty
```

Посмотреть созданные индексы и убедиться, что после вызовов demo API поступают trace-данные:

```bash
curl -k -u 'admin:YourSecurePassword123!' \
  'https://localhost:9200/_cat/indices?v'
```

В Dashboards откройте **Discover**, создайте data view для появившихся trace-индексов и отфильтруйте документы по `serviceName`, `demo-client` или `demo-server`. Bootstrap также добавляет Prometheus как data source для Dashboards.

## Метрики приложений в OpenSearch Dashboards

`server` экспортирует ASP.NET Core, HTTP и runtime-метрики. `client` экспортирует HTTP-метрики и собственные `demo.client.requests` и `demo.client.request.duration`. Collector передаёт эти метрики в Data Prepper по OTLP/gRPC, а Data Prepper сохраняет их в SS4O-схеме `ss4o_metrics-otel-*`.

После первого запуска подождите до минуты: стандартный OTLP metric exporter публикует данные периодически. Затем проверьте индекс:

```bash
curl -k -u 'admin:YourSecurePassword123!' \
  'https://localhost:9200/_cat/indices/ss4o_metrics-otel-*?v'
```

Data Prepper записывает метрики в OpenSearch, а не в Dashboards: Dashboards только запрашивает и визуализирует их. Bootstrap создаёт Data View **SS4O metrics** (`ss4o_metrics-otel-*`, поле времени `@timestamp`). Откройте его в **Discover** для просмотра необработанных документов или используйте его как источник визуализаций и обычных Dashboards. Если включён Metrics UI с необходимыми feature flags, выберите этот SS4O index там.

## Docker stdout/stderr в OpenSearch

`vector` подключается к read-only Docker socket и собирает stdout/stderr всех Compose-контейнеров, кроме самого себя. Логи маршрутизируются по владельцу приложения в три изолированных OpenSearch data streams:

| Контейнер | Data stream | Index template |
| --- | --- | --- |
| `demo-client` | `dev-app-client` | `templates/dev-app-client.json` |
| `demo-server` | `prod-app-server` | `templates/prod-app-server.json` |
| Все остальные | `prod-docker` | `templates/prod-docker.json` |

Каждый template задаёт `data_stream`, поле `@timestamp` и настройки single-node кластера (1 shard, 0 replicas). Vector использует Bulk API с действием `create`, поэтому OpenSearch автоматически создаёт data stream по совпадающему template при первой записи. Bootstrap загружает templates через `/_index_template/<name>` до запуска Vector.

### ISM policies

Положите JSON-описание policy в папку `policies/`. Bootstrap загрузит каждый файл через `/_plugins/_ism/policies/<name>`, где `<name>` — имя файла без расширения: например, `policies/docker-logs-retention.json` создаёт или обновляет policy `docker-logs-retention`. Папка изначально пуста; после добавления policy перезапустите bootstrap:

```bash
docker compose up --force-recreate opensearch-bootstrap
```

При ошибке bootstrap печатает имя JSON-файла, URL, HTTP status и headers, тело ответа OpenSearch и отправленный JSON.

В проект уже включены policies `dev-app-client-rollover`, `prod-app-server-rollover` и `prod-docker-rollover`. Каждая выполняет rollover backing index после 50 документов.

Доступ к логам также разделён по tenants: `dev_team_user` получает доступ только к `dev-app-client` и его backing indices; `prod_team_user` — только к `prod-app-server`, `prod-docker` и их backing indices. Следовательно, пользователь tenant `dev_team` не может прочитать логи tenant `prod_team`, включая запросы напрямую к OpenSearch API.

Проверка:

```bash
docker compose logs --tail=100 vector
curl -k -u 'admin:YourSecurePassword123!' \
  'https://localhost:9200/_data_stream/dev-app-client,prod-app-server,prod-docker?pretty'
```

Bootstrap добавляет Data View **Dev client logs** (`dev-app-client`) только в tenant `dev_team` и **Prod logs** (`prod-*`) только в `prod_team`. В Dashboards откройте **Discover** в назначенном tenant и выберите его Data View. Сохранённые поиски и dashboards также остаются изолированы tenants.

## Работа с Prometheus

Откройте [Targets](http://localhost:9090/targets) и проверьте статус `UP` у `otel-collector` и `prometheus`. Примеры запросов в [Expression browser](http://localhost:9090/graph):

```promql
up
```

```promql
otelcol_exporter_sent_spans
```

Если второй запрос не возвращает ряд в конкретной версии Collector, сначала найдите доступные имена через `http://localhost:8889/metrics`.

## Управление окружением

```bash
# Логи всех контейнеров
docker compose logs --follow

# Пересобрать и перезапустить только demo-приложения
docker compose up --build -d server client

# Остановить сервисы, сохранив данные в Docker volumes
docker compose down

# Полностью удалить сервисы и все данные OpenSearch, Prometheus и SeaweedFS
docker compose down --volumes
```

## Настройки для реального окружения

Этот Compose-файл не является production-конфигурацией. Перед развёртыванием за пределами локальной машины необходимо как минимум:

- вынести пароли и S3 key/secret из `docker-compose.yml`, `bootstrap.sh` и Dockerfile в secrets;
- не предоставлять Docker socket контейнеру Vector без необходимости: в production ограничьте его доступом только к нужным журналам или используйте выделенный log transport;
- заменить self-signed TLS OpenSearch на доверенный сертификат;
- закрыть или аутентифицировать SeaweedFS Admin UI;
- закрепить версии образов вместо `latest`;
- вынести client secret Keycloak и demo-пароли в Docker secrets, настроить TLS и разрешённые redirect URI для реального домена;
- заменить включённую только для Bootstrap настройку `plugins.security.unsupported.restapi.allow_securityconfig_modification` загрузкой проверенной Security-конфигурации до старта кластера;
- настроить резервное копирование Docker volumes и мониторинг доступности сервисов.
