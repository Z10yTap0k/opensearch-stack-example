package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

const maxTelegramMessageRunes = 4096

var telegramHTTPClient = &http.Client{Timeout: 10 * time.Second}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	telegramBotToken := os.Getenv("TELEGRAM_BOT_TOKEN")
	if telegramBotToken == "" {
		log.Printf("Telegram delivery is disabled: TELEGRAM_BOT_TOKEN is not set")
	}
	mux.HandleFunc("/notifications", receiveNotification(telegramBotToken))

	server := &http.Server{Addr: ":" + port, Handler: mux}
	log.Printf("notification webhook is listening on :%s", port)
	log.Fatal(server.ListenAndServe())
}

func receiveNotification(telegramBotToken string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
		if err != nil {
			http.Error(w, "notification body must not exceed 1 MiB", http.StatusRequestEntityTooLarge)
			return
		}

		log.Printf("notification received method=%s content_type=%q remote_addr=%q bytes=%d", r.Method, r.Header.Get("Content-Type"), r.RemoteAddr, len(body))

		var notification map[string]json.RawMessage
		if err := json.Unmarshal(body, &notification); err != nil {
			log.Printf("notification payload is not JSON: %q", body)
		} else if formatted, err := json.MarshalIndent(notification, "", "  "); err != nil {
			log.Printf("notification JSON could not be formatted: %v; raw=%q", err, body)
		} else {
			log.Printf("notification JSON:\n%s", formatted)
			if telegramBotToken != "" {
				if err := sendTelegramMessage(telegramBotToken, notification); err != nil {
					log.Printf("Telegram notification was not delivered: %v", err)
				}
			}
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

func sendTelegramMessage(botToken string, notification map[string]json.RawMessage) error {
	channelID, ok := notification["telegram_channel_id"]
	if !ok || len(channelID) == 0 || string(channelID) == `""` || string(channelID) == "null" {
		return fmt.Errorf("telegram_channel_id is missing from the alert payload")
	}

	var message string
	if rawMessage, ok := notification["message"]; !ok {
		return fmt.Errorf("message is missing from the alert payload")
	} else if err := json.Unmarshal(rawMessage, &message); err != nil || message == "" {
		return fmt.Errorf("message must be a non-empty JSON string")
	}

	message = truncateTelegramMessage(message)
	payload, err := json.Marshal(struct {
		ChatID                json.RawMessage `json:"chat_id"`
		Text                  string          `json:"text"`
		ParseMode             string          `json:"parse_mode"`
		DisableWebPagePreview bool            `json:"disable_web_page_preview"`
	}{
		ChatID:                channelID,
		Text:                  message,
		ParseMode:             "Markdown",
		DisableWebPagePreview: true,
	})
	if err != nil {
		return fmt.Errorf("encode Telegram request: %w", err)
	}

	request, err := http.NewRequest(http.MethodPost, "https://api.telegram.org/bot"+botToken+"/sendMessage", bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("create Telegram request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := telegramHTTPClient.Do(request)
	if err != nil {
		return fmt.Errorf("send Telegram request: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		responseBody, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return fmt.Errorf("Telegram API returned HTTP %d: %s", response.StatusCode, responseBody)
	}
	log.Printf("Telegram notification delivered to channel %s", channelID)
	return nil
}

func truncateTelegramMessage(message string) string {
	runes := []rune(message)
	if len(runes) <= maxTelegramMessageRunes {
		return message
	}
	return string(runes[:maxTelegramMessageRunes-1]) + "…"
}
