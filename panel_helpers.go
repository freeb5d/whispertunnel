package main

import (
	"crypto/rand"
	"regexp"
)

const randomCharset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

func randomString(n int) string {
	b := make([]byte, n)
	buf := make([]byte, n)
	_, _ = rand.Read(buf)
	for i := range b {
		b[i] = randomCharset[int(buf[i])%len(randomCharset)]
	}
	return string(b)
}

// replaceJSONField does a simple regex-based replace of a top-level string
// field's value in a small, known-shape JSON config file. Good enough for
// our flat config.json; not a general JSON editor.
func replaceJSONField(content, field, newValue string) string {
	re := regexp.MustCompile(`"` + field + `"\s*:\s*"[^"]*"`)
	return re.ReplaceAllString(content, `"`+field+`": "`+newValue+`"`)
}
