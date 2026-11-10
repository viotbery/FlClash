package core

import (
	"context"
	"io"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/ca"
)

const downloadTestURL = "https://speed.cloudflare.com/__down?bytes=52428800"
const downloadTestLimit = 50 << 20
const downloadSampleTime = 8 * time.Second
const downloadConnectTime = 10 * time.Second

type downloadSession struct {
	mu     sync.Mutex
	seq    uint64
	epoch  uint64
	id     string
	ctx    context.Context
	cancel context.CancelFunc
}

var downloads downloadSession
var downloadSlots = make(slots, 1)

func (s *downloadSession) begin(seq uint64) (string, error) {
	epoch := routeState().CoreEpoch
	s.mu.Lock()
	defer s.mu.Unlock()
	if seq <= s.seq {
		return "", &MethodError{Code: "cancelled", Message: "Download test superseded"}
	}
	if s.cancel != nil {
		s.cancel()
	}
	s.seq = seq
	s.epoch = epoch
	s.id = strconv.FormatUint(seq, 10)
	s.ctx, s.cancel = context.WithCancel(context.Background())
	return s.id, nil
}

func (s *downloadSession) end(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.id == id && s.cancel != nil {
		s.cancel()
		s.id = ""
	}
}

func (s *downloadSession) context(id string) context.Context {
	epoch := routeState().CoreEpoch
	s.mu.Lock()
	defer s.mu.Unlock()
	if id != "" && s.id == id && s.epoch == epoch {
		return s.ctx
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	return ctx
}

type downloadParams struct {
	Session string `json:"session"`
	Name    string `json:"name"`
}

type downloadResult struct {
	Name           string  `json:"name"`
	Bytes          int64   `json:"bytes"`
	Duration       int64   `json:"duration"`
	BytesPerSecond float64 `json:"bytesPerSecond"`
	Error          string  `json:"error"`
}

func startDownloadHandler(call *MethodCall) (any, error) {
	return downloads.begin(call.seq)
}

func handleCancelDownload(params downloadParams) error {
	downloads.end(params.Session)
	return nil
}

func handleTestDownload(params downloadParams) downloadResult {
	result := runDownload(downloads.context(params.Session), params.Name, downloadTestURL, downloadTestLimit, downloadSampleTime)
	if downloads.context(params.Session).Err() != nil {
		return downloadResult{Name: params.Name, Error: "cancelled"}
	}
	return result
}

func runDownload(parent context.Context, name, url string, limit int64, sampleTime time.Duration) downloadResult {
	result := downloadResult{Name: name}
	fail := func() downloadResult {
		result.Error = "failed"
		if parent.Err() != nil {
			result.Error = "cancelled"
		}
		return result
	}
	proxy := lookupProxy(name)
	if proxy == nil || isProxyGroupType(proxy.Type()) || parent.Err() != nil {
		return fail()
	}
	if !downloadSlots.acquireWithin(parent, downloadConnectTime) {
		return fail()
	}
	defer downloadSlots.release()
	ctx, cancel := context.WithTimeout(parent, downloadConnectTime+sampleTime)
	defer cancel()
	tlsConfig, err := ca.GetTLSConfig(ca.Option{})
	if err != nil {
		return fail()
	}
	dialer := &probeDialer{proxy: proxy}
	transport := &http.Transport{
		DialContext:           dialer.dial,
		TLSClientConfig:       tlsConfig,
		TLSHandshakeTimeout:   downloadConnectTime,
		ResponseHeaderTimeout: downloadConnectTime,
		DisableCompression:    true,
		DisableKeepAlives:     true,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return fail()
	}
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("Cache-Control", "no-cache")
	response, err := client.Do(request)
	if err != nil {
		return fail()
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || response.Header.Get("Content-Encoding") != "" && response.Header.Get("Content-Encoding") != "identity" {
		return fail()
	}
	var sampled atomic.Bool
	start := time.Now()
	timer := time.AfterFunc(sampleTime, func() {
		sampled.Store(true)
		cancel()
	})
	defer timer.Stop()
	result.Bytes, err = io.CopyBuffer(io.Discard, io.LimitReader(response.Body, limit), make([]byte, 32*1024))
	elapsed := time.Since(start)
	result.Duration = elapsed.Milliseconds()
	if parent.Err() != nil || result.Bytes == 0 || err != nil && !sampled.Load() {
		return fail()
	}
	result.BytesPerSecond = float64(result.Bytes) / elapsed.Seconds()
	return result
}
