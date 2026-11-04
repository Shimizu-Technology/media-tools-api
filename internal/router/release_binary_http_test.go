package router

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// Opt-in acceptance against the actual release executable with an allowlisted
// environment: no provider configuration or paid integrations are inherited.
func TestReleaseBinaryAuthHTTP(t *testing.T) {
	binary := os.Getenv("MTA_QA_BINARY")
	if binary == "" {
		t.Skip("MTA_QA_BINARY required")
	}
	f := newAuthHTTPFixture(t, true)
	email := uuid.NewString() + "@example.invalid"
	password := "synthetic release acceptance password"
	f.signup(email, password)
	era := f.login(email, password)
	if _, err := f.db.ExecContext(context.Background(), `UPDATE users SET clerk_id=$1 WHERE id=$2`, "retired-"+uuid.NewString(), era.UserID); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(binary)
	cmd.Dir = root
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "DATABASE_URL=" + os.Getenv("TEST_DATABASE_URL"), "PORT=" + fmt.Sprint(port), "JWT_SECRET=synthetic-local-release-secret-only-123456789", "FIRST_PARTY_AUTH_ENABLED=true", "FIRST_PARTY_PASSWORD_AUTH_ENABLED=true", "YT_DLP_PATH=/usr/bin/true", "EMAIL_DELIVERY=log"}
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { cmd.Process.Signal(os.Interrupt); cmd.Wait() }()
	session := os.Getenv("AUTH_QA_LIFECYCLE_SESSION")
	if session != "" {
		if err := exec.Command("dev-lifecycle", "claim", "--session", session, "--reason", "release binary auth acceptance", "process", fmt.Sprint(cmd.Process.Pid)).Run(); err != nil {
			t.Fatal(err)
		}
	}
	endpoint := fmt.Sprintf("http://127.0.0.1:%d", port)
	ready := false
	for i := 0; i < 100; i++ {
		res, err := http.Get(endpoint + "/health")
		if err == nil {
			res.Body.Close()
			ready = res.StatusCode == 200
			if ready {
				break
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ready {
		t.Fatal("release server did not boot")
	}
	f.server.URL = endpoint
	pair := f.login(email, password)
	next, _ := database.RandomFirstPartyRefreshToken()
	f.request("POST", "/api/v1/auth/session/refresh", gin.H{"refresh_token": era.RefreshToken, "next_refresh_token": next}, "", 200)
	raw := f.request("POST", "/api/v1/user/keys", gin.H{"name": "local acceptance", "scopes": []string{"library:read"}}, pair.AccessToken, 201)
	var key models.CreateAPIKeyResponse
	if err := json.Unmarshal(raw, &key); err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest("GET", endpoint+"/api/v1/library/items", nil)
	req.Header.Set("X-API-Key", key.RawKey)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 200 {
		t.Fatalf("scoped key status %d", res.StatusCode)
	}
	f.request("DELETE", "/api/v1/account", gin.H{"confirmation": "DELETE", "current_password": password}, pair.AccessToken, 202)
	t.Log("release binary: no provider environment; password sign-in, provider-era refresh, scoped key and deletion passed")
}
