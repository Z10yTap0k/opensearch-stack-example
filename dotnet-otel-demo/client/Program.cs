using System.Diagnostics;
using OpenTelemetry;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

// ---------------------------------------------------------------------------
// Configuration (override via environment variables)
//
//   SERVER_URL             target server endpoint        default: http://localhost:5000/api/test
//   INTERVAL_SECONDS       delay between calls           default: 10
//   OTEL_SERVICE_NAME      service name for the trace    default: demo-client
//   OTEL_EXPORTER_OTLP_ENDPOINT  OTLP collector endpoint default: http://localhost:4317
// ---------------------------------------------------------------------------
var serverUrl = Environment.GetEnvironmentVariable("SERVER_URL")
                ?? "http://localhost:5000/api/test";
var intervalSec = int.TryParse(Environment.GetEnvironmentVariable("INTERVAL_SECONDS"), out var parsed)
    ? parsed
    : 10;

var serviceName = Environment.GetEnvironmentVariable("OTEL_SERVICE_NAME")
                  ?? "demo-client";
var serviceVersion = "1.0.0";

var otlpEndpoint = Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT")
                   ?? "http://localhost:4317";

// A single shared HttpClient. The Http instrumentation automatically adds
// trace / baggage headers to every outgoing request, stitching the trace
// across the client and server.
var httpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };

// A dedicated source for our custom "call" span.
using var activitySource = new ActivitySource("OpenTelemetryDemo.Client");


var resourceBuilder = ResourceBuilder.CreateDefault()
    .AddService(serviceName, serviceVersion: serviceVersion);

// ---------------------------------------------------------------------------
// OpenTelemetry setup.
// ---------------------------------------------------------------------------
using var tracerProvider =
    Sdk.CreateTracerProviderBuilder().SetResourceBuilder(resourceBuilder)
        .AddSource(activitySource.Name) // our custom "InvokeServer" span
        .AddHttpClientInstrumentation() // automatic spans for HttpClient
        .AddConsoleExporter() // print spans to stdout
        .AddOtlpExporter(o =>
        {
            o.Endpoint = new Uri(otlpEndpoint);
            o.Protocol = OpenTelemetry.Exporter.OtlpExportProtocol.Grpc;
        })
        .Build();

Console.WriteLine($"[client] tracing enabled, service={serviceName}, otlp={otlpEndpoint}");
Console.WriteLine($"[client] calling {serverUrl} every {intervalSec}s "
                  + "(press Ctrl+C to stop)");

// ---------------------------------------------------------------------------
// Call loop.
// ---------------------------------------------------------------------------
using var stopping = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    stopping.Cancel();
};

while (!stopping.Token.IsCancellationRequested)
{
    var id = Guid.NewGuid();
    var url = $"{serverUrl}?id={id}";

    // A client span so each loop iteration is visible in the trace.
    using var activity = activitySource.StartActivity(
        "InvokeServer", ActivityKind.Producer);
    activity?.SetTag("demo.request_id", id);
    activity?.SetTag("demo.url", url);

    try
    {
        using var response = await httpClient.GetAsync(url, stopping.Token);
        var body = await response.Content.ReadAsStringAsync(stopping.Token);

        activity?.SetTag("http.status_code", (int)response.StatusCode);
        Console.WriteLine($"[{DateTimeOffset.Now:HH:mm:ss}] id={id} "
                          + $"status={(int)response.StatusCode} {response.StatusCode} -> {body}");
    }
    catch (OperationCanceledException)
    {
        // Either the call was cancelled by the user or the request timed out.
        Console.WriteLine($"[{DateTimeOffset.Now:HH:mm:ss}] request cancelled/timed out");
    }
    catch (Exception ex)
    {
        activity?.AddException(ex);
        activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
        Console.WriteLine($"[{DateTimeOffset.Now:HH:mm:ss}] id={id} error: {ex.Message}");
    }

    try
    {
        // Wait, but break quickly on Ctrl+C.
        await Task.Delay(TimeSpan.FromSeconds(intervalSec), stopping.Token);
    }
    catch (OperationCanceledException)
    {
        Console.WriteLine("[client] stopping...");
        break;
    }
}

// Flush any pending spans before we exit.
tracerProvider.Dispose();
Console.WriteLine("[client] done.");