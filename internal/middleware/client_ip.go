package middleware

import (
	"github.com/golang-jwt/jwt/v5"
	"net"
	"strings"

	"github.com/gin-gonic/gin"
)

// ClientIP supports explicitly trusted socket proxies and opt-in public Render
// edge headers. Netlify's client address requires its own signed proxy proof.
// Other deployments must never enable RenderPublicEdge: a directly reachable
// socket or private Render peer could forge CF-Connecting-IP.
type ClientIPOptions struct {
	RenderPublicEdge       bool
	NetlifySignatureSecret string
}

func ClientIP(trustedCIDRs []string, options ...ClientIPOptions) gin.HandlerFunc {
	var opts ClientIPOptions
	if len(options) > 0 {
		opts = options[0]
	}
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
		verifiedSource := false
		if ip != nil && trusted(ip) {
			values := c.Request.Header.Values("X-Forwarded-For")
			hops := len(values)
			for _, value := range values {
				hops += strings.Count(value, ",")
				if hops > 16 {
					break
				}
			}
			// Bound work and fall back completely when a trusted proxy sends malformed
			// data; skipping a bad hop would let a spoofed value jump the trust boundary.
			if hops <= 16 {
				parts := strings.Split(strings.Join(values, ","), ",")
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
				if valid && len(parts) > 0 && parts[0] != "" {
					verifiedSource = true
					ip = candidate
				}
			}
		}
		// Render documents that its PUBLIC Cloudflare edge overwrites this
		// header on every request, unlike X-Forwarded-For which can be appended
		// to a caller-controlled chain. Enable only on that ingress topology:
		// https://render.com/articles/host-pocketbase-on-render
		if opts.RenderPublicEdge {
			if edgeIP := singleHeaderIP(c, "CF-Connecting-IP"); edgeIP != nil {
				ip = edgeIP
				verifiedSource = true
			}
		}
		// A direct caller can forge X-Nf-Client-Connection-Ip. Accept it only
		// after validating Netlify's HS256 issuer, signature and required expiry.
		// The JWT authenticates proxy origin, not a user; it never grants access.
		// https://docs.netlify.com/manage/routing/redirects/rewrites-proxies/
		if validNetlifySignature(c, opts.NetlifySignatureSecret) {
			if netlifyIP := singleHeaderIP(c, "X-Nf-Client-Connection-Ip"); netlifyIP != nil {
				ip = netlifyIP
				verifiedSource = true
			}
		}
		c.Set("auth_client_ip_verified", verifiedSource)
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

func singleHeaderIP(c *gin.Context, name string) net.IP {
	values := c.Request.Header.Values(name)
	if len(values) != 1 {
		return nil
	}
	return net.ParseIP(strings.TrimSpace(values[0]))
}
func validNetlifySignature(c *gin.Context, secret string) bool {
	if secret == "" {
		return false
	}
	values := c.Request.Header.Values("X-Nf-Sign")
	if len(values) != 1 || len(values[0]) > 4096 {
		return false
	}
	token, err := jwt.Parse(values[0], func(token *jwt.Token) (any, error) { return []byte(secret), nil }, jwt.WithValidMethods([]string{"HS256"}), jwt.WithIssuer("netlify"), jwt.WithExpirationRequired())
	return err == nil && token.Valid
}
