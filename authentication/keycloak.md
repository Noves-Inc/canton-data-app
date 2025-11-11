# Keycloak Setup for Data App

This guide explains how to configure Keycloak authentication for the Data App. Keycloak is used to authenticate end users via the frontend UI using OpenID Connect (OIDC), and the backend simply passes through the user's JWT token to the Ledger API.

---

## Quick Reference: Critical Requirements

To successfully configure Keycloak for Noves Data App, you MUST:

1. ✅ **Create a Public Client** in Keycloak with Authorization Code + PKCE flow enabled
2. ✅ **Create the `daml_ledger_api` client scope** with proper mappers:
   - **Audience mapper** with `https://canton.network.global` (CRITICAL!)
   - User Client Role mapper (optional but recommended)
3. ✅ **Add `daml_ledger_api` as a DEFAULT scope** to your client (not optional)
4. ✅ **Verify tokens contain** `"aud": ["https://canton.network.global"]` using the Evaluate tab
5. ✅ **Create Canton users** whose IDs match the Keycloak user's UUID (`sub` claim)

**Most Common Issue:** Missing or incorrect audience claim → Canton returns `UNAUTHENTICATED`

**Solution:** Ensure the Audience mapper in `daml_ledger_api` scope is correctly configured with `https://canton.network.global`

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Keycloak Client Setup](#keycloak-client-setup)
4. [Keycloak Scope Configuration](#keycloak-scope-configuration)
5. [Canton User & Party Setup](#canton-user--party-setup)
6. [Verification & Testing](#verification--testing)
7. [Token Inspection](#token-inspection)
8. [Troubleshooting Keycloak Issues](#troubleshooting-keycloak-issues)

---

## Overview

The Data App requires **one Keycloak client**:

**Public Client** - For user authentication
- Allows end users to log into the dashboard
- Uses Authorization Code Flow with PKCE
- Issues user-scoped JWT tokens

### Authentication Flow

1. User logs into frontend via Keycloak (Public client)
2. Frontend receives JWT token from Keycloak
3. Frontend sends JWT token to backend with data requests
4. **Backend passes the same JWT token through to Canton's Ledger API**
5. Canton validates JWT and returns data for authorized parties only

**Important:** The backend does not authenticate with Keycloak directly. It simply forwards the user's JWT token from the frontend to Canton. The backend has no Keycloak credentials of its own.

---

## Prerequisites

- Access to your Keycloak instance with admin privileges
- Keycloak realm configured (create one if needed)
- Keycloak JWT validation configured in your validator node (if you used Keycloak when originally deploying the node, or if you're using Keycloak to log into the native Wallet UI, then this is already done)

---

## Keycloak Client Setup

### 1. Public Client - For User Authentication

#### Create Public Client

1. In Keycloak Admin Console → **Clients** → **Create client**
2. **General Settings:**
   - Client type: `OpenID Connect`
   - Client ID: `data-app-ui` (or similar)
   - Click **Next**
3. **Capability config:**
   - Client authentication: `OFF` (Public client)
   - Authorization: `OFF`
   - Authentication flow: Enable **Standard flow** and **Direct access grants**
   - Click **Next**
4. **Login settings:**
   - Valid redirect URIs: 
     ```
     https://canton-data-ui.yourdomain.com/callback
     ```
   - Valid post logout redirect URIs:
     ```
     https://canton-data-ui.yourdomain.com
     ```
   - Web origins: 
     ```
     https://canton-data-ui.yourdomain.com
     ```
   - Click **Save**

**Note:** Replace `yourdomain.com` with your actual domain.

#### Configure Client Settings

After creation, review the client settings:

**Access settings:**
- Root URL: `https://canton-data-ui.yourdomain.com`
- Home URL: `https://canton-data-ui.yourdomain.com`
- Valid redirect URIs: `https://canton-data-ui.yourdomain.com/callback`
- Valid post logout redirect URIs: `https://canton-data-ui.yourdomain.com`
- Web origins: `https://canton-data-ui.yourdomain.com`

**Advanced Settings (Optional):**
- Access Token Lifespan: Adjust if needed (default: 5 minutes)
- Proof Key for Code Exchange Code Challenge Method: `S256` (PKCE support)

### Optional: Configure Session Settings

For improved user experience with longer-lived sessions:

1. Navigate to **Realm Settings** → **Sessions**
2. Configure offline session settings (if using `offline_access` scope):
   - **Offline Session Max Limited**: `ON`
   - **Offline Session Max**: `5184000` seconds (60 days, adjust as needed)
   - **Offline Session Idle Timeout**: `2592000` seconds (30 days, adjust as needed)
3. Click **Save**

**Note:** These settings are useful if your application uses refresh tokens for long-lived sessions.

#### Note Down Client Information

You'll need these values for frontend configuration:
- **Keycloak URL**: `https://keycloak.yourdomain.com` (your Keycloak base URL)
- **Realm**: `your-realm-name`
- **Client ID**: `data-app-ui` (or whatever you named it)

**Keycloak OIDC Endpoints:**

Keycloak uses standard OpenID Connect endpoint paths. The frontend application automatically constructs these from your base URL and realm:

- **Authorization**: `https://keycloak.yourdomain.com/realms/{realm}/protocol/openid-connect/auth`
- **Token**: `https://keycloak.yourdomain.com/realms/{realm}/protocol/openid-connect/token`
- **Userinfo**: `https://keycloak.yourdomain.com/realms/{realm}/protocol/openid-connect/userinfo`
- **Logout**: `https://keycloak.yourdomain.com/realms/{realm}/protocol/openid-connect/logout`
- **Well-known config**: `https://keycloak.yourdomain.com/realms/{realm}/.well-known/openid-configuration`

You only need to provide the base URL and realm name - the application handles the rest.

---

## Keycloak Scope Configuration

### Important: Canton Network Compatibility

**Critical Requirement:** For Canton Network compatibility, your Keycloak client **must** have `daml_ledger_api` configured as a **default scope** with proper mappers.

This ensures that JWT tokens issued by Keycloak include the proper scope and audience that Canton expects for Ledger API access.

### Adding the daml_ledger_api Scope

#### Step 1: Create Client Scope (if not exists)

1. In Keycloak Admin Console → **Client scopes** → **Create client scope**
2. **General Settings:**
   - Name: `daml_ledger_api`
   - Protocol: `OpenID Connect`
   - Type: `Default`
   - Display on consent screen: `OFF` (for seamless authentication)
   - Include in token scope: `OFF`
   - Click **Save**

#### Step 2: Configure Scope Mappers

The `daml_ledger_api` scope requires two critical mappers for Canton compatibility:

**Audience Mapper (Critical for Canton):**

1. Navigate to **Client scopes** → `daml_ledger_api` → **Mappers** → **Add mapper** → **By configuration**
2. Select **Audience**
3. Configure:
   - **Name**: `audience` (or `canton-audience`)
   - **Mapper Type**: `Audience`
   - **Included Custom Audience**: `https://canton.network.global` ← **This exact value is required by Canton**
   - **Add to access token**: `ON`
   - **Add to token introspection**: `ON`
   - **Add to ID token**: `OFF`
   - **Add to lightweight access token**: `OFF`
4. Click **Save**

**User Client Role Mapper (Optional but recommended):**

1. Navigate to **Client scopes** → `daml_ledger_api` → **Mappers** → **Add mapper** → **By configuration**
2. Select **User Client Role**
3. Configure:
   - **Name**: `daml_ledger_api_scope`
   - **Mapper Type**: `User Client Role`
   - **Add to access token**: `ON`
   - **Add to ID token**: `OFF`
   - **Add to userinfo**: `OFF`
   - **Add to token introspection**: `OFF`
   - **Multivalued**: `OFF`
4. Click **Save**

#### Step 3: Add Scope to Client as Default Scope

1. Go to **Clients** → Select your client (`data-app-ui`)
2. Click **Client scopes** tab
3. Click **Add client scope**
4. Select `daml_ledger_api` from the list
5. **Important:** Choose **Default** (not Optional)
6. Click **Add**

#### Step 4: Verify Scope Configuration

To verify the scope is correctly configured:

1. Go to **Clients** → Your client → **Client scopes** tab
2. Under **Assigned default client scopes**, you should see `daml_ledger_api`
3. Click **Evaluate** tab to preview token claims
4. Select a user and verify the token includes:
   - `aud`: `["https://canton.network.global"]`
   - `scope`: should contain `daml_ledger_api` (if Include in token scope was ON)

**Why This Matters:**
- Canton **requires** JWT tokens to include `https://canton.network.global` in the `aud` (audience) claim
- The `daml_ledger_api` scope with the Audience mapper ensures this claim is present
- Without the correct audience in the token, Canton will reject authentication attempts with `UNAUTHENTICATED` errors
- Making it a **default scope** ensures it's always included without requiring explicit requests

---

## Canton User & Party Setup

For users to view data in the Data App, they must have Canton users with `can_read_as` rights for the relevant parties. This is the same setup used by Canton's native wallet.

> **Important:** If you're already using Keycloak with your Canton validator (e.g., for the Canton wallet), your users are likely already configured. **You can skip to [Verification & Testing](#verification--testing).**

### When You Need This Section

Only if you're:
- Setting up Keycloak authentication for the first time, OR  
- Granting additional users access to specific parties

If your users can already log into the Canton wallet with Keycloak, they can use the Data App with the same credentials—no additional setup needed.

### Vocabulary

- **Participant User**: A user object **inside Canton** (not Keycloak) whose `id` must equal the JWT token's `sub` claim
- **Party**: A Canton party identifier that can act on the ledger
- **Rights**: `can_act_as` (submit commands) and `can_read_as` (read ledger state)
- **Scope**: The `daml_ledger_api` scope required for Canton Network compatibility

> **Critical**: The Canton user ID must match the `sub` claim from the Keycloak JWT token. For Keycloak users, the `sub` claim is typically a UUID format like `f47ac10b-58cc-4372-a567-0e02b2c3d479`

If you need to create new Canton users or grant permissions:

**1. Get an admin token with `participant_admin` privileges:**

```bash
export KEYCLOAK_URL="https://keycloak.yourdomain.com"
export KEYCLOAK_REALM="your-realm-name"
export DOCKER_NETWORK="splice-validator_splice_validator"

# Get admin token (requires admin user credentials)
ADMIN_TOKEN_JSON=$(curl -s "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=<ADMIN_USERNAME>" \
  -d "password=<ADMIN_PASSWORD>")

export ADMIN_TOKEN=$(echo "$ADMIN_TOKEN_JSON" | jq -r .access_token)
```

**Note:** You may need to use a confidential client with client credentials flow instead of the admin-cli, depending on your Keycloak configuration.

**2. Get user's Keycloak ID:**

To find a user's `sub` claim (which will be their Canton user ID):

```bash
# List users in Keycloak (requires admin token)
curl -s "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/users" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq '.[] | {username, id}'

# Or get specific user
export KEYCLOAK_USER_ID="<user_uuid_from_keycloak>"
```

**3. Create Canton user and grant rights:**

```bash
# The USER_ID must match the 'sub' claim from the user's JWT token
export USER_ID="$KEYCLOAK_USER_ID"
export PARTY_ID="<party_id>"

# Create user
docker run --rm --network $DOCKER_NETWORK fullstorydev/grpcurl -plaintext \
  -H "authorization: Bearer $ADMIN_TOKEN" \
  -d '{"user":{"id":"'"$USER_ID"'"}}' \
  participant:5001 com.daml.ledger.api.v2.admin.UserManagementService/CreateUser

# Grant read rights
docker run --rm --network $DOCKER_NETWORK fullstorydev/grpcurl -plaintext \
  -H "authorization: Bearer $ADMIN_TOKEN" \
  -d '{"user_id":"'"$USER_ID"'","rights":[{"can_read_as":{"party":"'"$PARTY_ID"'"}}]}' \
  participant:5001 com.daml.ledger.api.v2.admin.UserManagementService/GrantUserRights
```

**Key Requirements:**
- The Canton `USER_ID` must exactly match the `sub` claim from the user's Keycloak JWT
- Users need `can_read_as` rights to view data in the Data App
- The `sub` claim in Keycloak is typically a UUID (e.g., `f47ac10b-58cc-4372-a567-0e02b2c3d479`)


At this point, Keycloak should be set up.
The docs below include information on how to verify and test the Keycloak setup. This requires the application to be deployed first. You can return to it after completing the deployment.
Next Installation Steps at: https://github.com/Noves-Inc/canton-data-app/blob/master/docker-compose/docker_compose_deployment.md.

---

## Verification & Testing

### Test User Login and Token

The easiest way to test is to have a user log into the frontend and verify their token:

1. Navigate to the frontend URL
2. Log in with Keycloak
3. Open browser developer tools → Console
4. The application should have received a JWT token

### Test Token Manually

If you need to test a user's token manually against Canton, you can extract it from the browser and test it.

### Test Canton Ledger API Access

Using a user's token, test access to Canton:

```bash
# Set to the user's JWT token (obtained from browser or Keycloak)
export ACCESS_TOKEN="<user_jwt_token>"

# Extract user ID from token
export USER_ID=$(echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq -r .sub)

echo "Testing access for user: $USER_ID"

# List user rights
docker run --rm --network $DOCKER_NETWORK fullstorydev/grpcurl -plaintext \
  -H "authorization: Bearer $ACCESS_TOKEN" \
  -d '{"user_id":"'"$USER_ID"'"}' \
  participant:5001 com.daml.ledger.api.v2.admin.UserManagementService/ListUserRights | jq .
```

Should return the `can_read_as` rights you granted earlier.

### Test Transaction Streaming

Test that you can stream transactions:

```bash
# Get party ID from previous step
export PARTY_ID="<your_party_id>"

# Stream transactions (will run indefinitely, Ctrl+C to stop)
docker run --rm --network $DOCKER_NETWORK fullstorydev/grpcurl -plaintext \
  -H "authorization: Bearer $ACCESS_TOKEN" \
  -d '{
    "begin": {"boundary": "LEDGER_BEGIN"},
    "filter": {
      "filters_by_party": {
        "'"$PARTY_ID"'": {}
      }
    }
  }' \
  participant:5001 com.daml.ledger.api.v2.UpdateService/GetUpdates
```

If successful, you'll see a stream of transactions (or an empty stream if no transactions exist).

### Test Frontend Login

1. Navigate to your frontend URL (e.g., `https://canton-data-ui.yourdomain.com`)
2. Click "Log in"
3. You should be redirected to Keycloak's login page
4. After successful authentication, you should be redirected back to the dashboard

If you get errors, check:
- Keycloak client redirect URIs are correctly configured
- Browser console for detailed error messages
- Network tab for failed requests

---

## Token Inspection

### Inspect JWT Token Claims

To inspect what's inside a JWT token:

```bash
# Decode token (assuming it's in $ACCESS_TOKEN)
echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .
```

**Key Claims to Verify:**
- `sub`: Should match Canton user ID (UUID format for Keycloak)
- `aud`: **MUST include `https://canton.network.global`** ← Critical for Canton authentication
- `scope`: Should include `daml_ledger_api` (if Include in token scope is ON)
- `iss`: Should be your Keycloak realm URL (e.g., `https://keycloak.yourdomain.com/realms/your-realm`)
- `exp`: Token expiration timestamp

**Example Token Payload:**
```json
{
  "sub": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "aud": ["https://canton.network.global"],  // ← CRITICAL: Must include this exact value
  "scope": "openid profile email",
  "iss": "https://keycloak.yourdomain.com/realms/your-realm",
  "exp": 1697654321,
  "iat": 1697654021,
  "azp": "data-app-ui",
  "preferred_username": "user@example.com"
}
```

**Important:** If the `aud` claim does NOT include `https://canton.network.global`, Canton will reject the token. This is why the Audience mapper in the `daml_ledger_api` scope is critical.

### Check Token Expiration

```bash
echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .exp | xargs -I{} date -r {}
```

### Check Token Audience (Critical)

```bash
echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .aud
# MUST include: "https://canton.network.global"
```

**This is the most important check.** Without the correct audience, Canton will always reject the token.

### Check Token Scope

```bash
echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .scope
# May include 'daml_ledger_api' depending on scope configuration
```

---

## Troubleshooting Keycloak Issues

### Token Request Fails

**Symptoms**: Authorization flow returns error or token cannot be obtained

**Common Errors:**

1. **`invalid_client`**
   - **Cause**: Wrong client ID or client configuration
   - **Solution**: Verify client ID in Keycloak dashboard and frontend configuration

2. **`unauthorized_client`**
   - **Cause**: Client not configured for authorization code flow
   - **Solution**: In Keycloak → Clients → Your client → Ensure "Standard flow" is enabled

3. **`invalid_redirect_uri`**
   - **Cause**: Redirect URI doesn't match configured values
   - **Solution**: Ensure redirect URI in frontend config exactly matches Keycloak client configuration

### Canton Returns UNAUTHENTICATED

**Symptoms**: gRPC calls return `UNAUTHENTICATED` error

**Solutions:**
1. **Check audience claim (MOST COMMON ISSUE):**
   ```bash
   echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .aud
   # MUST contain: "https://canton.network.global"
   ```
   If missing, verify:
   - `daml_ledger_api` scope has Audience mapper configured with `https://canton.network.global`
   - `daml_ledger_api` scope is assigned as a **default** scope to your client
   
2. Verify token is not expired:
   ```bash
   echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .exp | xargs -I{} date -r {}
   ```

3. Verify Canton participant has Keycloak JWT validation configured
4. Check Canton logs for JWT validation errors
5. Ensure issuer (`iss`) in token matches Canton's expected issuer

### Canton Returns PERMISSION_DENIED

**Symptoms**: gRPC calls return `PERMISSION_DENIED` error

**Solutions:**
1. Verify Canton user exists:
   ```bash
   docker run --rm --network $DOCKER_NETWORK fullstorydev/grpcurl -plaintext \
     -H "authorization: Bearer $ADMIN_TOKEN" \
     -d '{"user_id":"'"$USER_ID"'"}' \
     participant:5001 com.daml.ledger.api.v2.admin.UserManagementService/GetUser
   ```
2. Check user has required rights:
   ```bash
   docker run --rm --network $DOCKER_NETWORK fullstorydev/grpcurl -plaintext \
     -H "authorization: Bearer $ADMIN_TOKEN" \
     -d '{"user_id":"'"$USER_ID"'"}' \
     participant:5001 com.daml.ledger.api.v2.admin.UserManagementService/ListUserRights
   ```
3. Verify user ID exactly matches the `sub` claim from the JWT token
4. Ensure rights are granted for the correct party

### Frontend Redirect Loop

**Symptoms**: Frontend continuously redirects to Keycloak and back

**Solutions:**
1. Check client redirect URI in Keycloak matches frontend URL exactly
2. Verify `VITE_KEYCLOAK_REDIRECT_URI` in frontend config
3. Check browser console for specific error messages
4. Clear browser cookies and try again
5. Verify Keycloak client is configured as a public client (Client authentication: OFF)

### Frontend Shows Keycloak Error Page

**Symptoms**: Keycloak shows error after login attempt

**Common Errors:**

1. **`invalid_redirect_uri`**
   - **Cause**: Redirect URI mismatch
   - **Solution**: Ensure redirect URI in Keycloak exactly matches frontend URL

2. **`access_denied`**
   - **Cause**: User not authorized for the client
   - **Solution**: Check user permissions in Keycloak

3. **`invalid_request`**
   - **Cause**: Missing required parameters in authorization request
   - **Solution**: Check frontend Keycloak configuration for all required fields

### Token Sub Doesn't Match User ID

**Symptoms**: Canton user exists but token still fails authentication

**Solutions:**
1. Decode token and check `sub` claim:
   ```bash
   echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .sub
   ```
2. Ensure it exactly matches the Canton user ID
3. In Keycloak, the `sub` claim is always a UUID
4. Recreate Canton user with correct ID if mismatch

### Missing Canton Audience in Token

**Symptoms**: Token validation fails, Canton returns `UNAUTHENTICATED` errors, even though token appears valid

**This is the most common issue with Keycloak authentication.**

**Solutions:**
1. **Verify token contains the required audience:**
   ```bash
   echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .aud
   # MUST contain: "https://canton.network.global"
   ```

2. **If audience is missing or incorrect:**
   - Go to **Client scopes** → `daml_ledger_api` → **Mappers**
   - Verify there's an **Audience** mapper with:
     - Included Custom Audience: `https://canton.network.global`
     - Add to access token: `ON`
   - If mapper doesn't exist, create it (see [Keycloak Scope Configuration](#keycloak-scope-configuration))

3. **Verify scope is assigned to client:**
   - Go to **Clients** → Your client → **Client scopes** tab
   - Ensure `daml_ledger_api` is in **Assigned default client scopes** (not Optional)

4. **Test with Client Scope Evaluator:**
   - Go to **Clients** → Your client → **Client scopes** → **Evaluate** tab
   - Select a user and click **Generated access token**
   - Verify `aud` claim includes `https://canton.network.global`

5. After fixing, users need to log out and log back in to get new tokens

### CORS Errors in Browser

**Symptoms**: Browser console shows CORS errors when calling Keycloak

**Solutions:**
1. In Keycloak → Clients → Your client → Settings
2. Add frontend URL to:
   - Valid redirect URIs
   - Web origins
3. Ensure URLs are exact (including protocol and no trailing slash unless configured)
4. Check if Keycloak itself allows CORS (usually enabled by default for configured origins)

### Token Does Not Include Expected Claims

**Symptoms**: Token is valid but missing expected claims (email, name, etc.)

**Solutions:**
1. Configure client scopes to include desired claims:
   - Go to Clients → Your client → Client scopes tab
   - Add standard scopes like `profile`, `email` as default scopes
2. Configure mappers to include specific attributes:
   - Go to Client scopes → Select scope → Mappers
   - Add protocol mappers as needed
3. Ensure user attributes are populated in Keycloak user profile

### Keycloak Server Connection Issues

**Symptoms**: Frontend cannot connect to Keycloak

**Solutions:**
1. Verify `VITE_KEYCLOAK_URL` is correct and accessible from frontend
2. Check network connectivity to Keycloak server
3. Ensure Keycloak URL uses HTTPS in production
4. Verify Keycloak service is running:
   ```bash
   curl https://keycloak.yourdomain.com/realms/your-realm/.well-known/openid-configuration
   ```
5. Check Keycloak logs for errors


