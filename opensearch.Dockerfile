FROM opensearchproject/opensearch:latest

# Установка плагина S3
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch repository-s3

# Настройка доступов к MinIO во внутреннее защищенное хранилище ключей (Keystore)
RUN /usr/share/opensearch/bin/opensearch-keystore create
RUN echo "minioadmin" | /usr/share/opensearch/bin/opensearch-keystore add --stdin s3.client.default.access_key
RUN echo "MinioPassword123!" | /usr/share/opensearch/bin/opensearch-keystore add --stdin s3.client.default.secret_key
