using OpenTelemetry;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OpenTelemetryDemo.Server;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddLogging(logging => logging.AddConsole());

// ---------------------------------------------------------------------------
// OpenTelemetry configuration
//
// The service name and OTLP endpoint are read from standard OpenTelemetry
// environment variables automatically:
//     OTEL_SERVICE_NAME             -> "demo-server"
//     OTEL_EXPORTER_OTLP_ENDPOINT   -> "http://localhost:4317"
//
// They can also be provided through application configuration below.
// ---------------------------------------------------------------------------
var otlpEndpoint = Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT")
                   ?? "http://localhost:4317";

var serviceVersion = "1.0.0";
var serviceName = Environment.GetEnvironmentVariable("OTEL_SERVICE_NAME")
                  ?? "demo-server";

var resourceBuilder = ResourceBuilder.CreateDefault()
    .AddService(serviceName, serviceVersion: serviceVersion);

builder.Services.AddOpenTelemetry()
    .WithTracing(tracing =>
        tracing
            .SetResourceBuilder(resourceBuilder)
            // Instrument the ASP.NET Core request pipeline (creates the root span).
            .AddAspNetCoreInstrumentation()
            .AddHttpClientInstrumentation()
            // Listen to our own ActivitySource used inside the controller.
            .AddSource(TestController.SActivitySource.Name)
            // Export to stdout (handy for the local demo / containers).
            .AddConsoleExporter()
            // Export to an OTLP collector (Jaeger, Tempo, Grafana, ...).
            .AddOtlpExporter(o =>
            {
                o.Endpoint = new Uri(otlpEndpoint);
                o.Protocol = OpenTelemetry.Exporter.OtlpExportProtocol.Grpc;
            }))
    .WithMetrics(metrics => metrics
        .SetResourceBuilder(resourceBuilder)
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddRuntimeInstrumentation()
        .AddConsoleExporter()
        .AddOtlpExporter(o =>
        {
            o.Endpoint = new Uri(otlpEndpoint);
            o.Protocol = OpenTelemetry.Exporter.OtlpExportProtocol.Grpc;
        })
    );

// ---------------------------------------------------------------------------
// Application wiring
// ---------------------------------------------------------------------------
builder.Services.AddControllers();

// A friendly banner so you know which service is running where.
Console.WriteLine("[server] OpenTelemetry tracing enabled -> service=" + serviceName
                                                                       + ", otlp=" + otlpEndpoint);

var app = builder.Build();

// Lightweight health endpoint.
app.MapGet("/health", () => Results.Ok(new { status = "ok", time = DateTimeOffset.Now }));

app.MapControllers();

app.Run();

// Required so integration tests / hosted code can reference the app.
public partial class Program
{
}
