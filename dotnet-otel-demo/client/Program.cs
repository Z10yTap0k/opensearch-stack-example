using System.Diagnostics;
using System.Diagnostics.Metrics;
using Microsoft.Extensions.Logging;
using OpenTelemetry;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
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
                ?? throw new Exception("unset SERVER_URL");

var intervalSec = int.TryParse(Environment.GetEnvironmentVariable("INTERVAL_SECONDS"), out var parsed)
    ? parsed
    : 10;

var serviceName = Environment.GetEnvironmentVariable("OTEL_SERVICE_NAME")
                  ?? throw new Exception("unset OTEL_SERVICE_NAME");

var serviceVersion = "1.0.0";

var otlpEndpoint = Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT")
                   ?? throw new Exception("unset OTEL_EXPORTER_OTLP_ENDPOINT");

// A single shared HttpClient. The Http instrumentation automatically adds
// trace / baggage headers to every outgoing request, stitching the trace
// across the client and server.
var httpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };

// A dedicated source for our custom "call" span.
using var activitySource = new ActivitySource("OpenTelemetryDemo.Client");
using var meter = new Meter("OpenTelemetryDemo.Client");
var requestCounter = meter.CreateCounter<long>("custom.client.requests");
var requestDuration = meter.CreateHistogram<double>("custom.client.request.duration", unit: "ms");


var resourceBuilder = ResourceBuilder.CreateDefault()
    .AddService(serviceName, serviceVersion: serviceVersion);

using var loggerFactory = LoggerFactory.Create(logging =>
{
    logging.AddOpenTelemetry(options =>
    {
        options.SetResourceBuilder(resourceBuilder);
        options.IncludeFormattedMessage = true;
        options.IncludeScopes = true;
        options.ParseStateValues = true;
        options.AddOtlpExporter(o =>
        {
            o.Endpoint = new Uri(otlpEndpoint);
            o.Protocol = OpenTelemetry.Exporter.OtlpExportProtocol.Grpc;
        });
    });
});
var logger = loggerFactory.CreateLogger("OpenTelemetryDemo.Client");

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

using var meterProvider =
    Sdk.CreateMeterProviderBuilder().SetResourceBuilder(resourceBuilder)
        .AddMeter(meter.Name)
        .AddMeter("System.Net.Http")
        .AddConsoleExporter()
        .AddOtlpExporter(o =>
        {
            o.Endpoint = new Uri(otlpEndpoint);
            o.Protocol = OpenTelemetry.Exporter.OtlpExportProtocol.Grpc;
        })
        .Build();

logger.LogInformation(
    "OpenTelemetry logs, traces, and metrics enabled; service={ServiceName}, otlp={OtlpEndpoint}",
    serviceName,
    otlpEndpoint);
logger.LogInformation("Calling {ServerUrl} every {IntervalSeconds} seconds", serverUrl, intervalSec);

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
        var requestStarted = Stopwatch.GetTimestamp();
        using var response = await httpClient.GetAsync(url, stopping.Token);
        var body = await response.Content.ReadAsStringAsync(stopping.Token);

        activity?.SetTag("http.status_code", (int)response.StatusCode);
        requestCounter.Add(1, new KeyValuePair<string, object?>("http.response.status_code", (int)response.StatusCode));
        requestDuration.Record(Stopwatch.GetElapsedTime(requestStarted).TotalMilliseconds,
            new KeyValuePair<string, object?>("http.response.status_code", (int)response.StatusCode));
        logger.LogInformation(
            "Server request completed; requestId={RequestId}, statusCode={StatusCode}, responseBody={ResponseBody}",
            id,
            (int)response.StatusCode,
            body);
    }
    catch (OperationCanceledException)
    {
        // Either the call was cancelled by the user or the request timed out.
        logger.LogWarning("Server request was cancelled or timed out");
    }
    catch (Exception ex)
    {
        activity?.AddException(ex);
        activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
        logger.LogError(ex, "Server request failed; requestId={RequestId}", id);
    }

    try
    {
        // Wait, but break quickly on Ctrl+C.
        await Task.Delay(TimeSpan.FromSeconds(intervalSec), stopping.Token);
    }
    catch (OperationCanceledException)
    {
        logger.LogInformation("Client stopping");
        break;
    }
}

// Flush any pending spans before we exit.
tracerProvider.Dispose();
logger.LogInformation("Client stopped");
