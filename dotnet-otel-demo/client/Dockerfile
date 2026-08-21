# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build context = the "client/" folder, i.e. run this from the repo root with:
#     docker build -t demo-client ./client
#
# Stage 1: build
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore first so NuGet packages are cached in a separate layer.
COPY client.csproj ./
RUN dotnet restore client.csproj

# Copy the remaining source and publish.
COPY . ./
RUN dotnet publish client.csproj -c Release -o /app --no-restore

# ---------------------------------------------------------------------------
# Stage 2: run
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/runtime:10.0 AS run
WORKDIR /app
COPY --from=build /app ./

# The runtime image already runs as the non-root "app" user.
USER app

# Where the client should call the server. In docker-compose the server service
# is reachable at http://server:5000.
ENV SERVER_URL=http://server:5000/api/test \
    INTERVAL_SECONDS=10 \
    OTEL_SERVICE_NAME=demo-client \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
    OTEL_TRACES_EXPORTER=otlp

ENTRYPOINT ["dotnet", "client.dll"]
