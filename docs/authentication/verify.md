# Verify authentication

Before starting the Noves Data App, request another M2M indexing token and confirm its exact, case-sensitive `sub` still matches the Canton user.

After installation, verify the backend:

```bash
curl -fsS http://127.0.0.1:8090/ready
curl -fsS http://127.0.0.1:8090/api/v2/capture/status | jq
```

Then open `APP_URL`, sign in through the configured identity provider, and confirm the browser returns to `APP_URL/callback`.

A successful token exchange does not prove that M2M indexing works. The app must also confirm the participant identity, network, token subject, and `CanReadAsAnyParty` without broader rights.
