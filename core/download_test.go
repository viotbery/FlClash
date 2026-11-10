package core

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestDownloadCapsBytesAndMeasuresThroughput(t *testing.T) {
	withProbeProxies(t, "node")
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept-Encoding") != "identity" {
			t.Error("download must not count decompressed bytes")
		}
		fmt.Fprint(w, strings.Repeat("x", 8192))
	})
	result := runDownload(context.Background(), "node", server.URL, 4096, time.Second)
	if result.Error != "" || result.Bytes != 4096 || result.BytesPerSecond <= 0 || result.Name != "node" {
		t.Fatalf("unexpected download: %+v", result)
	}
}

func TestDownloadRejectsBadResponsesAndMissingNodes(t *testing.T) {
	withProbeProxies(t, "node")
	for _, code := range []int{http.StatusForbidden, http.StatusNoContent, http.StatusOK} {
		t.Run(fmt.Sprint(code), func(t *testing.T) {
			server := probeServer(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(code) })
			result := runDownload(context.Background(), "node", server.URL, 4096, time.Second)
			if result.Error != "failed" || result.BytesPerSecond != 0 {
				t.Fatalf("unexpected result: %+v", result)
			}
		})
	}
	result := runDownload(context.Background(), "missing", "http://127.0.0.1:1", 4096, time.Second)
	if result.Error != "failed" {
		t.Fatalf("missing proxy must not fall back to routing: %+v", result)
	}
}

func TestDownloadSamplesSlowBodyAndCancelsRead(t *testing.T) {
	withProbeProxies(t, "node")
	for _, cancelEarly := range []bool{false, true} {
		t.Run(fmt.Sprint(cancelEarly), func(t *testing.T) {
			started := make(chan struct{})
			server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
				fmt.Fprint(w, strings.Repeat("x", 1024))
				w.(http.Flusher).Flush()
				close(started)
				<-r.Context().Done()
			})
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			resultCh := make(chan downloadResult, 1)
			go func() { resultCh <- runDownload(ctx, "node", server.URL, 4096, 100*time.Millisecond) }()
			<-started
			if cancelEarly {
				cancel()
			}
			select {
			case result := <-resultCh:
				if cancelEarly {
					if result.Error != "cancelled" || result.BytesPerSecond != 0 {
						t.Fatalf("unexpected cancel: %+v", result)
					}
				} else if result.Error != "" || result.Bytes != 1024 || result.Duration < 80 || result.BytesPerSecond <= 0 {
					t.Fatalf("unexpected sample: %+v", result)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("download did not close the blocked body")
			}
		})
	}
}

func TestDownloadRejectsTruncatedBody(t *testing.T) {
	withProbeProxies(t, "node")
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "1000")
		fmt.Fprint(w, "truncated")
	})
	result := runDownload(context.Background(), "node", server.URL, 4096, time.Second)
	if result.Error != "failed" || result.BytesPerSecond != 0 {
		t.Fatalf("truncated body counted as a speed: %+v", result)
	}
}

func TestDownloadSessionCancellationAndLatestStart(t *testing.T) {
	var session downloadSession
	first, err := session.begin(1)
	if err != nil {
		t.Fatal(err)
	}
	firstCtx := session.context(first)
	second, err := session.begin(3)
	if err != nil {
		t.Fatal(err)
	}
	defer session.end(second)
	if firstCtx.Err() == nil {
		t.Fatal("new session did not cancel old download")
	}
	session.end(first)
	if session.context(second).Err() != nil {
		t.Fatal("stale cancellation stopped new session")
	}
	if _, err := session.begin(2); err == nil {
		t.Fatal("late start replaced newer session")
	}
	session.end(second)
	if session.context(second).Err() == nil {
		t.Fatal("test arriving after cancellation started again")
	}
}

func TestDownloadSessionRejectsChangedConfig(t *testing.T) {
	var session downloadSession
	id, err := session.begin(1)
	if err != nil {
		t.Fatal(err)
	}
	defer session.end(id)
	currentRoute.mu.Lock()
	epoch := currentRoute.epoch
	currentRoute.epoch++
	currentRoute.mu.Unlock()
	t.Cleanup(func() {
		currentRoute.mu.Lock()
		currentRoute.epoch = epoch
		currentRoute.mu.Unlock()
	})
	if session.context(id).Err() == nil {
		t.Fatal("download accepted a different config")
	}
}
