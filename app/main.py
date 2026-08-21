import time
import logging
from opentelemetry import trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource

# 1. Общие метаданные сервиса
resource = Resource(attributes={
    "service.name": "demo-python-service",
    "environment": "production"
})

# 2. НАСТРОЙКА ТРЕЙСОВ (Отправка по HTTP на OTel Collector)
trace_provider = TracerProvider(resource=resource)
# По умолчанию для HTTP эндпоинт OTLP — http://хост:порт/v1/traces
trace_exporter = OTLPSpanExporter(endpoint="http://otel-collector:4318/v1/traces")
trace_provider.add_span_processor(BatchSpanProcessor(trace_exporter))
trace.set_tracer_provider(trace_provider)
tracer = trace.get_tracer(__name__)

# 3. НАСТРОЙКА ЛОГОВ (Отправка по HTTP на OTel Collector)
log_provider = LoggerProvider(resource=resource)
# По умолчанию для HTTP эндпоинт OTLP — http://хост:порт/v1/logs
log_exporter = OTLPLogExporter(endpoint="http://otel-collector:4318/v1/logs")
log_provider.add_log_record_processor(BatchLogRecordProcessor(log_exporter))
set_logger_provider(log_provider)

# Интегрируем лог-провайдер OpenTelemetry со стандартным модулем logging в Python
handler = LoggingHandler(level=logging.INFO, logger_provider=log_provider)
logger = logging.getLogger(__name__)
logger.addHandler(handler)
logger.setLevel(logging.INFO)

# Также выводим в консоль контейнера для локальной наглядности
console_handler = logging.StreamHandler()
console_handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - %(message)s"))
logger.addHandler(console_handler)

print("Приложение запущено. Отправка телеметрии идет через OTLP/HTTP...", flush=True)

iteration = 0
while True:
    iteration += 1
    
    # Создаем блок распределенного трейса (Span)
    with tracer.start_as_current_span("ProcessUserRequest") as span:
        span.set_attribute("request.id", iteration)
        
        # Этот лог автоматически получит context (trace_id и span_id) и улетит по HTTP
        logger.info(f"Получен запрос №{iteration}. Начинаем обработку.")
        time.sleep(0.4)
        
        with tracer.start_as_current_span("DatabaseQuery") as db_span:
            db_span.set_attribute("db.system", "postgresql")
            
            if iteration % 5 == 0:
                logger.warning(f"Запрос к БД занял больше времени на итерации {iteration}!")
                db_span.set_attribute("db.slow_query", True)
            else:
                logger.info("Запрос к БД выполнен успешно.")
            time.sleep(0.2)
            
        logger.info(f"Запрос №{iteration} успешно обработан.")
    
    time.sleep(3)
