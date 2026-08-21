## .NET 10 + OpenTelemetry tracing demo

Two small .NET 10 services that demonstrate distributed tracing with
OpenTelemetry:

* **server** — an ASP.NET Core Web API exposing `GET /api/test?id={guid}`.
  It emulates ~1 second of work and writes a child span for the "work".
* **client** — a console app that, every 10 seconds, calls the server with a
  random GUID and wraps each call in its own client span.

The `W3C` trace context (trace-id / parent-id) is propagated over HTTP
automatically, so a request shows up as a single trace spanning both
services. Each app also exports its spans to **stdout** (via the Console
exporter) and, optionally, to an **OTLP collector**.

```
client  --HTTP (traceparent header)-->  server
   |                                     |
   +--> OTLP/GRPC:4317 <----------------+ --> otel collector (debug)
```

## Prerequisites

* [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
  (>= 10.0.100) to run locally.
* Docker + Docker Compose to run the container demo.

## Run locally (no containers)

```bash
# terminal 1 — start the server on http://localhost:5000
cd server && dotnet run

# terminal 2 — start the client
cd client && dotnet run
```

You'll see trace spans printed to both consoles. To send them to a collector,
run a collector locally (e.g.
`docker run -p 4317:4317 -p 4318:4318 -v $PWD/otel-collector-config.yaml:/etc/otelcol/config.yaml:ro otel/opentelemetry-collector-contrib` )
and set `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317` when starting the
apps.

## Run with Docker Compose

```bash
docker compose up --build
```

This builds both apps and starts an OpenTelemetry collector that prints the
traces to its logs:

```bash
docker compose logs -f otelcollector
```

Or run the services individually:

```bash
docker build -t demo-server ./server
docker build -t demo-client ./client

docker run -e OTEL_SERVICE_NAME=demo-server \
            -e OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
            -p 5000:5000 demo-server

docker run -e SERVER_URL=http://localhost:5000/api/test \
            -e OTEL_SERVICE_NAME=demo-client demo-client
```

## Configuration (environment variables)

| Variable                         | Default                       | Meaning                              |
|----------------------------------|-------------------------------|--------------------------------------|
| `OTEL_SERVICE_NAME`              | `demo-server` / `demo-client` | Service name written to the trace.   |
| `OTEL_EXPORTER_OTLP_ENDPOINT`    | `http://localhost:4317`       | OTLP/GRPC collector endpoint.        |
| `SERVER_URL`                      | `http://localhost:5000/api/test` (client only) | Target URL. |
| `INTERVAL_SECONDS`                | `10`                          | Delay between client calls.          |

## Project layout

```
.
├─ demo.sln
├─ docker-compose.yml
├─ otel-collector-config.yaml
├─ server/
│   ├─ Dockerfile
│   ├─ server.csproj
│   ├─ Program.cs           # ASP.NET Core host + OTel setup
│   └─ TestController.cs    # GET /api/test?id={guid}
└─ client/
    ├─ Dockerfile
    ├─ client.csproj
    └─ Program.cs           # call loop + OTel setup
```
