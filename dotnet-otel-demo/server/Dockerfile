# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build context = the "server/" folder, i.e. run this from the repo root with:
#     docker build -t demo-server ./server
#
# Stage 1: build
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore first so NuGet packages are cached in a separate layer.
COPY server.csproj ./
RUN dotnet restore server.csproj

# Copy the remaining source and publish.
COPY . ./
RUN dotnet publish server.csproj -c Release -o /app --no-restore

# ---------------------------------------------------------------------------
# Stage 2: run
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS run
WORKDIR /app
COPY --from=build /app ./

# The runtime image already runs as the non-root "app" user.
USER app

# The port the app listens on (also overridable via ASPNETCORE_URLS).
ENV ASPNETCORE_URLS=http://+:5000

# OpenTelemetry configuration. Override with `docker run -e` or compose.
ENV OTEL_SERVICE_NAME=demo-server \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
    OTEL_TRACES_EXPORTER=otlp

EXPOSE 5000

ENTRYPOINT ["dotnet", "server.dll"]
