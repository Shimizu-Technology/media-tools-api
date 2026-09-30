package router

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/fxamacker/cbor/v2"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const testPasskeyRPID = "media.shimizu-technology.com"
const testPasskeyOrigin = "https://media.shimizu-technology.com"

type passkeyOptionsResponse struct {
	CeremonyID string `json:"ceremony_id"`
	Options    struct {
		RP struct {
			ID string `json:"id"`
		} `json:"rp"`
		RPID      string `json:"rpId"`
		Challenge string `json:"challenge"`
		User      struct {
			ID string `json:"id"`
		} `json:"user"`
	} `json:"options"`
}

func postPasskeyJSON(t *testing.T, engine *gin.Engine, path string, body any, bearer string) *httptest.ResponseRecorder {
	t.Helper()
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(data))
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	response := httptest.NewRecorder()
	engine.ServeHTTP(response, req)
	return response
}

func getPasskeyJSON(t *testing.T, engine *gin.Engine, path, bearer string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	response := httptest.NewRecorder()
	engine.ServeHTTP(response, req)
	return response
}

func newTestRefreshToken(t *testing.T) string {
	t.Helper()
	token, err := database.RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	return token
}

func readPasskeyOptions(t *testing.T, response *httptest.ResponseRecorder) passkeyOptionsResponse {
	t.Helper()
	if response.Code != http.StatusOK || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("passkey begin response = %d, cache=%q: %s", response.Code, response.Header().Get("Cache-Control"), response.Body.String())
	}
	var body passkeyOptionsResponse
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil || body.CeremonyID == "" || body.Options.Challenge == "" {
		t.Fatalf("invalid passkey options = %#v, %v", body, err)
	}
	return body
}

func createVirtualPasskeyRegistration(t *testing.T, challenge string) (map[string]any, *ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	id := make([]byte, 32)
	if _, err := rand.Read(id); err != nil {
		t.Fatal(err)
	}
	x, y := key.PublicKey.X.FillBytes(make([]byte, 32)), key.PublicKey.Y.FillBytes(make([]byte, 32))
	coseKey, err := cbor.Marshal(map[int]any{1: 2, 3: -7, -1: 1, -2: x, -3: y})
	if err != nil {
		t.Fatal(err)
	}
	rpHash := sha256.Sum256([]byte(testPasskeyRPID))
	authData := append([]byte{}, rpHash[:]...)
	authData = append(authData, 0x45)                // user present, verified, and attested credential data
	authData = append(authData, 0, 0, 0, 0)          // initial signature counter
	authData = append(authData, make([]byte, 16)...) // AAGUID
	length := make([]byte, 2)
	binary.BigEndian.PutUint16(length, uint16(len(id)))
	authData = append(authData, length...)
	authData = append(authData, id...)
	authData = append(authData, coseKey...)
	attestation, err := cbor.Marshal(map[string]any{"fmt": "none", "attStmt": map[string]any{}, "authData": authData})
	if err != nil {
		t.Fatal(err)
	}
	clientData, err := json.Marshal(map[string]any{"type": "webauthn.create", "challenge": challenge, "origin": testPasskeyOrigin})
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{
		"id":    base64.RawURLEncoding.EncodeToString(id),
		"rawId": base64.RawURLEncoding.EncodeToString(id),
		"type":  "public-key",
		"response": map[string]any{
			"clientDataJSON":    base64.RawURLEncoding.EncodeToString(clientData),
			"attestationObject": base64.RawURLEncoding.EncodeToString(attestation),
		},
	}, key, id
}

func createVirtualPasskeyAssertion(t *testing.T, challenge, origin string, key *ecdsa.PrivateKey, credentialID, userHandle []byte) map[string]any {
	t.Helper()
	rpHash := sha256.Sum256([]byte(testPasskeyRPID))
	authData := append([]byte{}, rpHash[:]...)
	authData = append(authData, 0x05, 0, 0, 0, 1) // present + verified; counter 1
	clientData, err := json.Marshal(map[string]any{"type": "webauthn.get", "challenge": challenge, "origin": origin})
	if err != nil {
		t.Fatal(err)
	}
	clientHash := sha256.Sum256(clientData)
	signed := append(append([]byte{}, authData...), clientHash[:]...)
	digest := sha256.Sum256(signed)
	signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{
		"id":    base64.RawURLEncoding.EncodeToString(credentialID),
		"rawId": base64.RawURLEncoding.EncodeToString(credentialID),
		"type":  "public-key",
		"response": map[string]any{
			"authenticatorData": base64.RawURLEncoding.EncodeToString(authData),
			"clientDataJSON":    base64.RawURLEncoding.EncodeToString(clientData),
			"signature":         base64.RawURLEncoding.EncodeToString(signature),
			"userHandle":        base64.RawURLEncoding.EncodeToString(userHandle),
		},
	}
}

func TestPasskeyRegistrationAndLoginHTTP(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.New(url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.RunMigrations("../../migrations"); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	var userID string
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name) VALUES ($1, '', 'Passkey HTTP Test') RETURNING id`, uuid.NewString()+"@example.com").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })
	firstSession, err := db.CreateFirstPartySession(ctx, userID, "web", "First browser")
	if err != nil {
		t.Fatal(err)
	}
	secondSession, err := db.CreateFirstPartySession(ctx, userID, "web", "Second browser")
	if err != nil {
		t.Fatal(err)
	}
	engine := Setup(RouterConfig{DB: db, FirstPartyAuthEnabled: true, JWTSecret: "test-only"})
	registerBegin := "/api/v1/auth/passkeys/register/begin"
	registerFinish := "/api/v1/auth/passkeys/register/finish"
	statusPath := "/api/v1/auth/passkeys"
	loginBegin := "/api/v1/auth/passkeys/login/begin"
	loginFinish := "/api/v1/auth/passkeys/login/finish"

	if response := postPasskeyJSON(t, engine, registerBegin, map[string]any{}, ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated registration = %d", response.Code)
	}
	legacy, err := middleware.GenerateJWT(&models.User{ID: userID, Email: "legacy@example.com"}, "test-only")
	if err != nil {
		t.Fatal(err)
	}
	if response := postPasskeyJSON(t, engine, registerBegin, map[string]any{}, legacy); response.Code != http.StatusUnauthorized {
		t.Fatalf("legacy JWT enrolled passkey = %d", response.Code)
	}
	if response := getPasskeyJSON(t, engine, statusPath, legacy); response.Code != http.StatusUnauthorized {
		t.Fatalf("legacy JWT checked passkeys = %d", response.Code)
	}
	if response := getPasskeyJSON(t, engine, statusPath, firstSession.AccessToken); response.Code != http.StatusOK || response.Body.String() != `{"count":0}` || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("initial passkey status = %d %q", response.Code, response.Body.String())
	}
	begin := readPasskeyOptions(t, postPasskeyJSON(t, engine, registerBegin, map[string]any{}, firstSession.AccessToken))
	if begin.Options.RP.ID != testPasskeyRPID || begin.Options.User.ID == "" {
		t.Fatalf("registration RP/user options = %#v", begin.Options)
	}
	registration, privateKey, credentialID := createVirtualPasskeyRegistration(t, begin.Options.Challenge)
	finishBody := map[string]any{"ceremony_id": begin.CeremonyID, "credential": registration}
	if response := postPasskeyJSON(t, engine, registerFinish, finishBody, secondSession.AccessToken); response.Code != http.StatusUnauthorized {
		t.Fatalf("other session finished registration = %d: %s", response.Code, response.Body.String())
	}
	finish := postPasskeyJSON(t, engine, registerFinish, finishBody, firstSession.AccessToken)
	if finish.Code != http.StatusCreated {
		t.Fatalf("registration finish = %d: %s", finish.Code, finish.Body.String())
	}
	if response := getPasskeyJSON(t, engine, statusPath, firstSession.AccessToken); response.Code != http.StatusOK || response.Body.String() != `{"count":1}` {
		t.Fatalf("registered passkey status = %d %q", response.Code, response.Body.String())
	}
	if response := postPasskeyJSON(t, engine, registerFinish, finishBody, firstSession.AccessToken); response.Code != http.StatusUnauthorized {
		t.Fatalf("replayed registration = %d", response.Code)
	}
	if response := postPasskeyJSON(t, Setup(RouterConfig{DB: db, JWTSecret: "test-only"}), loginBegin, map[string]any{}, ""); response.Code != http.StatusNotFound {
		t.Fatalf("disabled passkey route = %d", response.Code)
	}
	revokedBegin := readPasskeyOptions(t, postPasskeyJSON(t, engine, registerBegin, map[string]any{}, secondSession.AccessToken))
	revokedRegistration, _, _ := createVirtualPasskeyRegistration(t, revokedBegin.Options.Challenge)
	if revoked, err := db.RevokeFirstPartySession(ctx, userID, secondSession.SessionID); err != nil || !revoked {
		t.Fatalf("revoke registration session = %v, %v", revoked, err)
	}
	if response := postPasskeyJSON(t, engine, registerFinish, map[string]any{"ceremony_id": revokedBegin.CeremonyID, "credential": revokedRegistration}, secondSession.AccessToken); response.Code != http.StatusUnauthorized {
		t.Fatalf("revoked session finished registration = %d: %s", response.Code, response.Body.String())
	}

	login := readPasskeyOptions(t, postPasskeyJSON(t, engine, loginBegin, map[string]any{}, ""))
	if login.Options.RPID != testPasskeyRPID {
		t.Fatalf("login RP ID = %q", login.Options.RPID)
	}
	handle := uuid.MustParse(userID)
	assertion := createVirtualPasskeyAssertion(t, login.Options.Challenge, testPasskeyOrigin, privateKey, credentialID, handle[:])
	nextRefresh := newTestRefreshToken(t)
	loginBody := map[string]any{"ceremony_id": login.CeremonyID, "credential": assertion, "client_type": "web", "device_name": "Browser", "next_refresh_token": nextRefresh}
	webResponse := postPasskeyJSON(t, engine, loginFinish, loginBody, "")
	if webResponse.Code != http.StatusBadRequest || bytes.Contains(webResponse.Body.Bytes(), []byte("access_token")) || bytes.Contains(webResponse.Body.Bytes(), []byte("refresh_token")) {
		t.Fatalf("raw web passkey login leaked credentials = %d: %s", webResponse.Code, webResponse.Body.String())
	}
	loginBody["client_type"] = "ios"
	response := postPasskeyJSON(t, engine, loginFinish, loginBody, "")
	if response.Code != http.StatusCreated || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("passkey login = %d: %s", response.Code, response.Body.String())
	}
	var pair database.AuthTokenPair
	if err := json.Unmarshal(response.Body.Bytes(), &pair); err != nil || pair.UserID != userID || pair.AccessToken == "" || pair.RefreshToken != nextRefresh {
		t.Fatalf("passkey session = %#v, %v", pair, err)
	}
	if authenticated, _, err := db.GetUserByFirstPartyAccessToken(ctx, pair.AccessToken); err != nil || authenticated.ID != userID {
		t.Fatalf("passkey session resolved wrong user: %#v, %v", authenticated, err)
	}
	retry := postPasskeyJSON(t, engine, loginFinish, map[string]any{"ceremony_id": login.CeremonyID, "client_type": "ios", "next_refresh_token": nextRefresh}, "")
	var recovered database.AuthTokenPair
	if retry.Code != http.StatusCreated || json.Unmarshal(retry.Body.Bytes(), &recovered) != nil ||
		recovered.SessionID != pair.SessionID || recovered.RefreshToken != nextRefresh || recovered.AccessToken == pair.AccessToken {
		t.Fatalf("lost passkey response recovery = %d %#v: %s", retry.Code, recovered, retry.Body.String())
	}
	wrongSuccessor := newTestRefreshToken(t)
	wrongRetry := postPasskeyJSON(t, engine, loginFinish, map[string]any{"ceremony_id": login.CeremonyID, "client_type": "ios", "next_refresh_token": wrongSuccessor}, "")
	if wrongRetry.Code != http.StatusUnauthorized || bytes.Contains(wrongRetry.Body.Bytes(), []byte("access_token")) || bytes.Contains(wrongRetry.Body.Bytes(), []byte("refresh_token")) {
		t.Fatalf("wrong passkey successor = %d: %s", wrongRetry.Code, wrongRetry.Body.String())
	}

	wrongOrigin := readPasskeyOptions(t, postPasskeyJSON(t, engine, loginBegin, map[string]any{}, ""))
	badAssertion := createVirtualPasskeyAssertion(t, wrongOrigin.Options.Challenge, "https://attacker.example", privateKey, credentialID, handle[:])
	badNext := newTestRefreshToken(t)
	badLogin := postPasskeyJSON(t, engine, loginFinish, map[string]any{"ceremony_id": wrongOrigin.CeremonyID, "credential": badAssertion, "client_type": "ios", "next_refresh_token": badNext}, "")
	if badLogin.Code != http.StatusUnauthorized {
		t.Fatalf("wrong origin accepted = %d: %s", badLogin.Code, badLogin.Body.String())
	}
	validAfterBad := createVirtualPasskeyAssertion(t, wrongOrigin.Options.Challenge, testPasskeyOrigin, privateKey, credentialID, handle[:])
	if replay := postPasskeyJSON(t, engine, loginFinish, map[string]any{"ceremony_id": wrongOrigin.CeremonyID, "credential": validAfterBad, "client_type": "ios", "next_refresh_token": badNext}, ""); replay.Code != http.StatusUnauthorized {
		t.Fatalf("failed passkey ceremony was reusable = %d: %s", replay.Code, replay.Body.String())
	}
	wrongChallenge := readPasskeyOptions(t, postPasskeyJSON(t, engine, loginBegin, map[string]any{}, ""))
	challengeAssertion := createVirtualPasskeyAssertion(t, login.Options.Challenge, testPasskeyOrigin, privateKey, credentialID, handle[:])
	if response := postPasskeyJSON(t, engine, loginFinish, map[string]any{"ceremony_id": wrongChallenge.CeremonyID, "credential": challengeAssertion, "client_type": "ios", "next_refresh_token": newTestRefreshToken(t)}, ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("wrong challenge accepted = %d: %s", response.Code, response.Body.String())
	}
	badSignature := readPasskeyOptions(t, postPasskeyJSON(t, engine, loginBegin, map[string]any{}, ""))
	otherKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	forgedAssertion := createVirtualPasskeyAssertion(t, badSignature.Options.Challenge, testPasskeyOrigin, otherKey, credentialID, handle[:])
	if response := postPasskeyJSON(t, engine, loginFinish, map[string]any{"ceremony_id": badSignature.CeremonyID, "credential": forgedAssertion, "client_type": "ios", "next_refresh_token": newTestRefreshToken(t)}, ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("invalid signature accepted = %d: %s", response.Code, response.Body.String())
	}
	if _, err := db.ExecContext(ctx, `DELETE FROM users WHERE id = $1`, userID); err != nil {
		t.Fatal(err)
	}
	deleted := readPasskeyOptions(t, postPasskeyJSON(t, engine, loginBegin, map[string]any{}, ""))
	deletedAssertion := createVirtualPasskeyAssertion(t, deleted.Options.Challenge, testPasskeyOrigin, privateKey, credentialID, handle[:])
	if response := postPasskeyJSON(t, engine, loginFinish, map[string]any{"ceremony_id": deleted.CeremonyID, "credential": deletedAssertion, "client_type": "ios", "next_refresh_token": newTestRefreshToken(t)}, ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("deleted account signed in = %d: %s", response.Code, response.Body.String())
	}
}
