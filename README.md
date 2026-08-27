# OpenSearch observability stack

Docker Compose окружение для локальной разработки: демо-приложение на .NET отправляет трейсы, логи и метрики в OpenTelemetry Collector. Трейсы поступают в Data Prepper и OpenSearch, метрики — в Prometheus, а логи архивируются в S3-совместимое хранилище SeaweedFS.

## Состав стека

- **OpenSearch** — поиск и хранение данных наблюдаемости.
- **OpenSearch Dashboards** — web-интерфейс для просмотра данных OpenSearch.
- **OpenTelemetry Collector** — принимает OTLP-телеметрию от демо-приложений.
- **Data Prepper** — получает трейсы из Collector и передаёт их в OpenSearch.
- **Prometheus** — хранит метрики; bootstrap-скрипт добавляет его как data source в Dashboards.
- **SeaweedFS** — single-node S3-хранилище с Admin UI и одним persistent Docker volume (`seaweedfs-data`). При запуске создаются бакеты `opensearch-snapshots` и `otel-archive`.
- **demo-server** и **demo-client** — .NET-пример, периодически генерирующий запросы и телеметрию.

## Запуск

Требуются Docker Engine и Docker Compose v2.

```bash
docker compose up --build -d
```

Проверить состояние контейнеров:

```bash
docker compose ps
```

Остановить стек, сохранив данные в Docker volumes:

```bash
docker compose down
```

Для удаления контейнеров вместе с данными выполните `docker compose down -v`.

## Web-интерфейсы и API

| Компонент | Адрес | Назначение |
| --- | --- | --- |
| OpenSearch Dashboards | [http://localhost:5601](http://localhost:5601) | Поиск, дашборды и данные observability |
| OpenSearch API | [https://localhost:9200](https://localhost:9200) | REST API OpenSearch |
| Prometheus | [http://localhost:9090](http://localhost:9090) | Метрики и PromQL |
| SeaweedFS Admin UI | [http://localhost:23646](http://localhost:23646) | Администрирование SeaweedFS |
| SeaweedFS S3 API | [http://localhost:9000](http://localhost:9000) | S3-совместимый endpoint для клиентов |
| Demo server | [http://localhost:5000](http://localhost:5000) | API демо-приложения |

## Учётные данные для локального запуска

| Сервис | Логин | Пароль |
| --- | --- | --- |
| OpenSearch / Dashboards | `admin` | `YourSecurePassword123!` |
| SeaweedFS S3 | `minioadmin` | `MinioPassword123!` |

Эти реквизиты предназначены только для локальной разработки. Перед публикацией портов во внешнюю сеть замените пароли и ограничьте доступ к SeaweedFS Admin UI.

## Потоки телеметрии

```text
demo-server / demo-client
          |
          v
 OpenTelemetry Collector
   |         |          |
   v         v          v
Prometheus Data Prepper SeaweedFS S3
              |
              v
         OpenSearch
              |
              v
   OpenSearch Dashboards
```

S3 endpoint внутри Docker-сети: `http://seaweedfs:8333`. Внешний порт `9000` сохранён для удобства S3-клиентов на хосте.
