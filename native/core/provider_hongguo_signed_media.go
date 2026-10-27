// SPDX-License-Identifier: GPL-3.0-only
package core

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	hongguoSignedMediaURL = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/"
	hongguoSignedMediaUA  = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
)

func hongguoPlaybackDeviceID() (string, error) {
	var raw [6]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", errors.New("红果播放设备参数生成失败")
	}
	var value uint64
	for _, part := range raw {
		value = value<<8 | uint64(part)
	}
	return strconv.FormatUint(1_000_000_000_000_000+value, 10), nil
}

func hongguoSignedMediaQuery(deviceID, installID string, timestamp, ticket int64) string {
	fields := [][2]string{
		{"ac", "wifi"}, {"channel", "update_64"}, {"aid", "8662"}, {"app_name", "novelread"},
		{"version_code", "71332"}, {"version_name", "7.1.3.32"}, {"device_platform", "android"},
		{"os", "android"}, {"ssmix", "a"}, {"device_type", "25053RT47C"}, {"device_brand", "Redmi"},
		{"language", "zh"}, {"os_api", "36"}, {"os_version", "16"}, {"manifest_version_code", "71332"},
		{"resolution", "1280*2772"}, {"dpi", "520"}, {"update_version_code", "71332"},
		{"host_abi", "arm64-v8a"}, {"dragon_device_type", "phone"}, {"pv_player", "71332"},
		{"compliance_status", "0"}, {"need_personal_recommend", "1"}, {"player_so_load", "1"},
		{"is_android_pad_screen", "0"}, {"iid", installID}, {"device_id", deviceID},
		{"ts", strconv.FormatInt(timestamp, 10)}, {"_rticket", strconv.FormatInt(ticket, 10)},
	}
	parts := make([]string, 0, len(fields))
	for _, field := range fields {
		parts = append(parts, url.QueryEscape(field[0])+"="+url.QueryEscape(field[1]))
	}
	return strings.Join(parts, "&")
}

func (downloader *Downloader) resolveHongguoSignedMedia(ctx context.Context, videoID string) (providerMedia, error) {
	ctx, cancel := context.WithTimeout(ctx, 16*time.Second)
	defer cancel()
	body, err := json.Marshal(map[string]any{
		"biz_param": map[string]any{
			"detail_page_version": 0, "device_level": 3, "disable_digg_stat": false,
			"need_all_video_definition": true, "need_mp4_align": false,
			"use_os_player": false, "use_server_dns": false, "video_platform": 1024,
		},
		"mixed_video_id_map": map[string]any{"1004": []string{videoID}},
	})
	if err != nil {
		return providerMedia{}, err
	}
	deviceID, err := hongguoPlaybackDeviceID()
	if err != nil {
		return providerMedia{}, err
	}
	installID, err := hongguoPlaybackDeviceID()
	if err != nil {
		return providerMedia{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, hongguoSignedMediaURL, bytes.NewReader(body))
	if err != nil {
		return providerMedia{}, err
	}
	request.Header.Set("User-Agent", hongguoSignedMediaUA)
	request.Header.Set("Accept", "application/json; charset=utf-8,application/x-protobuf")
	request.Header.Set("Content-Type", "application/json; charset=UTF-8")
	request.Header.Set("X-XS-From-Web", "0")
	request.Header.Set("X-Tt-Request-Tag", "t=0;n=0")
	request.Header.Set("Sdk-Version", "2")
	request.Header.Set("Passport-Sdk-Version", "50561")
	request.Header.Set("X-Vc-Bdturing-Sdk-Version", "3.7.2.cn")
	request.Header.Set("X-Tt-Dt", "")
	result, err := downloader.hongguoPlaybackJSON(request, func(prepared *http.Request) error {
		now := time.Now()
		for offset := int64(0); offset < 32; offset++ {
			ticket := now.UnixMilli() + offset
			query := hongguoSignedMediaQuery(deviceID, installID, now.Unix(), ticket)
			if hgBranchOf(query, body, uint32(now.Unix())) == 1 {
				continue
			}
			prepared.URL.RawQuery = query
			prepared.Header.Set("X-SS-Req-Ticket", strconv.FormatInt(ticket, 10))
			prepared.Header.Set("X-SS-STUB", hgMd5HexUpper(body))
			for name, value := range hongguoPureSign(prepared.URL.String(), body, uint32(now.Unix())) {
				prepared.Header.Set(name, value)
			}
			return nil
		}
		return errors.New("红果播放签名参数暂不可用")
	})
	if err != nil {
		return providerMedia{}, err
	}
	entry := nestedMap(nestedMap(result, "data"), videoID)
	if len(entry) == 0 {
		return providerMedia{}, errors.New("红果批量接口未返回所选分集")
	}
	model, err := hongguoVideoModel(entry)
	if err != nil {
		return providerMedia{}, err
	}
	if _, ok := model["fallback_api"]; !ok {
		return hongguoSignedDirectMedia(model)
	}
	fallback, err := hongguoFallbackAPI(model)
	if err != nil {
		return providerMedia{}, err
	}
	data, err := downloader.fetchHongguoFallbackVideoData(ctx, fallback)
	if err != nil {
		return providerMedia{}, err
	}
	return hongguoMediaFromFallbackData(model, data)
}

func hongguoSignedDirectMedia(model map[string]any) (providerMedia, error) {
	media, err := selectHongguoAppMedia(model)
	if err != nil {
		return providerMedia{}, err
	}
	var variants []providerMedia
	for _, variant := range media.Variants {
		if hongguoAllowedMediaURL(variant.URL) {
			variant.Referer = ""
			variant.credentials = &providerMediaCredentials{userAgent: hongguoSignedMediaUA}
			variants = append(variants, variant)
		}
	}
	if len(variants) == 0 {
		return providerMedia{}, errors.New("红果批量接口未返回允许的媒体地址")
	}
	selected := variants[0]
	selected.Variants = variants
	return selected, nil
}

func (downloader *Downloader) hongguoPlaybackJSON(request *http.Request, prepare func(*http.Request) error) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(request.Context(), 8*time.Second)
	defer cancel()
	request = request.Clone(ctx)
	if downloader.limiter != nil {
		release, err := downloader.limiter.acquire(ctx, request)
		if err != nil {
			return nil, err
		}
		defer release()
	}
	if prepare != nil {
		if err := prepare(request); err != nil {
			return nil, err
		}
	}
	client := *downloader.client
	client.Jar = nil
	previousRedirect := client.CheckRedirect
	client.CheckRedirect = func(next *http.Request, via []*http.Request) error {
		if request.Method != http.MethodGet || len(via) >= 3 || !hongguoAllowedFallbackURL(next.URL) {
			return errors.New("红果播放接口跳转无效")
		}
		if previousRedirect != nil {
			return previousRedirect(next, via)
		}
		return nil
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if downloader.limiter != nil {
		downloader.limiter.observe(request, response)
	}
	observeSourceResponse(ctx, response)
	content, err := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK {
		return nil, downloader.catalogResponseError(request, response, content)
	}
	if len(bytes.TrimSpace(content)) == 0 || len(content) > providerMaxBodyBytes {
		return nil, errors.New("红果播放接口未返回有效数据")
	}
	var result map[string]any
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	if decoder.Decode(&result) != nil || len(result) == 0 {
		return nil, errors.New("红果播放接口返回格式异常")
	}
	if err := hongguoPlaybackResponseError(result); err != nil {
		return nil, err
	}
	return result, nil
}

func hongguoPlaybackResponseError(result map[string]any) error {
	code := firstNonEmpty(mapString(result, "code", "Code", "status_code"), mapString(nestedMap(result, "BaseResp"), "StatusCode"))
	if code != "" && code != "0" {
		return fmt.Errorf("红果播放接口暂不可用（%s）", truncate(code, 20))
	}
	return nil
}
