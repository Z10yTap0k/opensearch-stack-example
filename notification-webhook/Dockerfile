FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /notification-webhook .

FROM alpine:3.22
RUN adduser -D -H -u 10001 webhook
USER webhook
COPY --from=build /notification-webhook /notification-webhook
EXPOSE 8080
ENTRYPOINT ["/notification-webhook"]
