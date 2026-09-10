package main

import (
	"crypto/rand"
	"math/big"
	"sync"
	"time"
)

const randomCharset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

// randomString returns a random string of n characters drawn uniformly from
// randomCharset via rejection sampling. (A plain `buf[i] % len(charset)`
// would work but introduces modulo bias since 256 isn't a multiple of 62 —
// low-value bytes map to slightly more charset entries than high ones,
// making the resulting key marginally easier to guess.)
func randomString(n int) string {
	b := make([]byte, n)
	max := big.NewInt(int64(len(randomCharset)))
	for i := range b {
		idx, err := rand.Int(rand.Reader, max)
		if err != nil {
			panic(err) // no entropy source available; nothing sane to do
		}
		b[i] = randomCharset[idx.Int64()]
	}
	return string(b)
}

// rateLimiter is a simple fixed-window counter per key, used to throttle
// repeated failed logins against the panel from a given source IP.
type rateLimiter struct {
	mu       sync.Mutex
	limit    int
	window   time.Duration
	attempts map[string][]time.Time
}

func newRateLimiter(limit int, window time.Duration) *rateLimiter {
	return &rateLimiter{
		limit:    limit,
		window:   window,
		attempts: make(map[string][]time.Time),
	}
}

// Allow reports whether another attempt for key is permitted, recording it
// if so. Old attempts outside the window are pruned on each call.
func (rl *rateLimiter) Allow(key string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-rl.window)
	var kept []time.Time
	for _, t := range rl.attempts[key] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}

	if len(kept) >= rl.limit {
		rl.attempts[key] = kept
		return false
	}

	rl.attempts[key] = append(kept, now)
	return true
}

// Reset clears recorded attempts for key, e.g. after a successful login.
func (rl *rateLimiter) Reset(key string) {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	delete(rl.attempts, key)
}
