package middleware

import (
	"net"
	"strings"

	"github.com/gin-gonic/gin"
)

// ClientIP trusts X-Forwarded-For only when the socket peer belongs to an
// explicitly configured proxy network. Walk from the nearest hop backwards,
// stopping at the first untrusted address. Never use the leftmost value or
// X-Nf-Client-Connection-Ip on a publicly reachable Render origin: a direct
// caller can supply either. Both Render AND Netlify hops must be allowlisted
// before a proxied browser's address becomes the limit key. Empty config is
// deliberately safe (socket peer only), though it may share a proxy bucket.
func ClientIP(trustedCIDRs []string) gin.HandlerFunc {
	networks := make([]*net.IPNet, 0, len(trustedCIDRs))
	for _, cidr := range trustedCIDRs {
		if strings.TrimSpace(cidr) == "" {
			continue
		}
		_, network, err := net.ParseCIDR(strings.TrimSpace(cidr))
		if err != nil {
			panic("invalid TRUSTED_PROXY_CIDRS")
		}
		if ones, _ := network.Mask.Size(); ones == 0 {
			panic("TRUSTED_PROXY_CIDRS cannot trust the entire internet")
		}
		networks = append(networks, network)
	}
	trusted := func(ip net.IP) bool {
		for _, network := range networks {
			if network.Contains(ip) {
				return true
			}
		}
		return false
	}
	return func(c *gin.Context) {
		peer, _, err := net.SplitHostPort(c.Request.RemoteAddr)
		if err != nil {
			peer = c.Request.RemoteAddr
		}
		ip := net.ParseIP(peer)
		if ip != nil && trusted(ip) {
			parts := strings.Split(c.GetHeader("X-Forwarded-For"), ",")
			// Bound work and fall back completely when a trusted proxy sends malformed
			// data; skipping a bad hop would let a spoofed value jump the trust boundary.
			if len(parts) <= 16 {
				candidate := ip
				valid := true
				for i := len(parts) - 1; i >= 0 && trusted(candidate); i-- {
					next := net.ParseIP(strings.TrimSpace(parts[i]))
					if next == nil {
						valid = false
						break
					}
					candidate = next
				}
				if valid {
					ip = candidate
				}
			}
		}
		if ip != nil {
			c.Set("auth_client_ip", ip.String())
		} else {
			c.Set("auth_client_ip", peer)
		}
		c.Next()
	}
}
func AuthClientIP(c *gin.Context) string {
	if ip := c.GetString("auth_client_ip"); ip != "" {
		return ip
	}
	peer, _, err := net.SplitHostPort(c.Request.RemoteAddr)
	if err != nil {
		return c.Request.RemoteAddr
	}
	return peer
}
