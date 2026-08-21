using System.Diagnostics;
using Microsoft.AspNetCore.Mvc;

namespace OpenTelemetryDemo.Server;

/// <summary>
/// Demo endpoint. Handles GET /api/test?id=&lt;guid&gt; and emulates ~1 second
/// of work while leaving a detailed child span open in the trace.
/// </summary>
[ApiController]
[Route("api")]
public class TestController : ControllerBase
{
    private readonly ILogger<TestController> _logger;

    // Reused ActivitySource; the incoming request already has a server span
    // created by the AspNetCore instrumentation, so this child span shows the
    // "work" portion of the trace.
    public static readonly ActivitySource SActivitySource =
        new("OpenTelemetryDemo.Server");

    public TestController(ILogger<TestController> logger)
    {
        _logger = logger;
    }

    /// <summary>
    /// GET /api/test?id={id} — emulates 1s of work and reports status.
    /// </summary>
    [HttpGet("test")]
    public async Task<IActionResult> Test([FromQuery] Guid id, CancellationToken cancellationToken)
    {
        _logger.LogInformation("Test called with id={id}", id);
        using var activity = SActivitySource.StartActivity(
            "TestController.Test", ActivityKind.Server);
        activity?.SetTag("demo.id", id);

        var start = System.Diagnostics.Stopwatch.StartNew();
        await Task.Delay(1000, cancellationToken);
        start.Stop();
        var elapsedMs = start.ElapsedMilliseconds;

        activity?.SetTag("demo.elapsed_ms", elapsedMs);
        activity?.AddEvent(new ActivityEvent("work.completed"));

        return Ok(new
        {
            status = "ok",
            echoId = id,
            serverUtc = DateTimeOffset.UtcNow,
            workMs = elapsedMs,
            service = "demo-server"
        });
    }
}