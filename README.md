# OpenSearch observability stack

Готовый локальный стенд observability на Docker Compose. Он демонстрирует путь OpenTelemetry-трейса от .NET-приложения до OpenSearch, сбор метрик Prometheus и S3-совместимое хранилище SeaweedFS для логов и snapshot-репозитория OpenSearch.

Это проект для разработки и экспериментов: пароли заданы прямо в конфигурации, TLS OpenSearch использует self-signed сертификат, а порты открыты на `localhost`.

## Что разворачивается

| Сервис | Роль | Данные |
| --- | --- | --- |
| `server` | ASP.NET Core API с OpenTelemetry-инструментацией | Нет persistent-данных |
| `client` | Каждые 30 секунд вызывает API и создаёт трейсы | Нет persistent-данных |
| `otel-collector` | Принимает OTLP по gRPC/HTTP; отправляет трейсы в Data Prepper | Нет persistent-данных |
| `data-prepper` | Преобразует трейсы и записывает trace analytics в OpenSearch | Нет persistent-данных |
| `opensearch` | Хранит индексы, включая trace analytics | `opensearch-data` |
| `opensearch-dashboards` | Интерфейс поиска и визуализации OpenSearch | Нет persistent-данных |
| `prometheus` | Хранит метрики и опрашивает метрики Collector | `prometheus-data` |
| `seaweedfs` | Одноузловой S3 API и Admin UI; один SeaweedFS volume server | `seaweedfs-data` |
| `opensearch-bootstrap` | Одноразово создаёт тенанты, S3 snapshot repository и Prometheus data source | Нет persistent-данных |

## Схема данных

```text
demo-client ──HTTP──> demo-server
     │                    │
     └──── OTLP/gRPC ─────┘
                 │
                 v
       OpenTelemetry Collector
          │              │
          │ traces       │ OTLP logs (если их отправляет клиент)
          v              v
      Data Prepper   SeaweedFS / otel-archive
          │
          v
      OpenSearch <── OpenSearch Dashboards

Prometheus ──scrape──> OpenTelemetry Collector :8889
```

Демо-приложения создают трейсы автоматически. Логовый S3 pipeline и OTLP metrics pipeline уже настроены, но чтобы в них появились прикладные логи или метрики, клиент должен экспортировать их по OTLP.

## Требования

- Docker Engine с запущенным daemon;
- Docker Compose v2 (`docker compose version`);
- свободные порты: `5000`, `5601`, `9000`, `9090`, `9200`, `23646`, `4317`, `4318`, `8889`, `21890`, `21891`;
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
| OpenSearch Dashboards | [http://localhost:5601](http://localhost:5601) | Войти под `admin`, открыть Discover или раздел observability и искать данные trace analytics. |
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
| SeaweedFS S3 | `minioadmin` | `MinioPassword123!` |

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
- заменить self-signed TLS OpenSearch на доверенный сертификат;
- закрыть или аутентифицировать SeaweedFS Admin UI;
- закрепить версии образов вместо `latest`;
- настроить резервное копирование Docker volumes и мониторинг доступности сервисов.
