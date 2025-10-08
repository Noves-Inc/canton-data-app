# Auth0 Setup for Data App

This guide explains how to configure Auth0 authentication for the Data App. Auth0 is used to authenticate end users via the frontend UI, and the backend simply passes through the user's JWT token to the Ledger API.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Auth0 Application Setup](#auth0-application-setup)
4. [Canton User & Party Setup](#canton-user--party-setup)
5. [Verification & Testing](#verification--testing)
6. [Token Inspection](#token-inspection)
7. [Troubleshooting Auth0 Issues](#troubleshooting-auth0-issues)

---

## Overview

The Data App requires **one Auth0 application**:

**Single Page Application (SPA)** - For user authentication
- Allows end users to log into the dashboard
- Uses Authorization Code Flow with PKCE
- Issues user-scoped JWT tokens

### Authentication Flow

1. User logs into frontend via Auth0 (SPA application)
2. Frontend receives JWT token from Auth0
3. Frontend sends JWT token to backend with data requests
4. **Backend passes the same JWT token through to Canton's Ledger API**
5. Canton validates JWT and returns data for authorized parties only

**Important:** The backend does not authenticate with Auth0 directly. It simply forwards the user's JWT token from the frontend to Canton. The backend has no Auth0 credentials of its own.

---

## Prerequisites

- Access to your Auth0 tenant with admin privileges
- Auth0 JWT validation configured in your validator node (if you used Auth0 when originally deploying the node, or if you're using Auth0 to log into the native Wallet UI, then this is already done)

---

## Auth0 Application Setup

### 1. Single Page Application (SPA) - For User Authentication

#### Create SPA Application

1. In Auth0 Dashboard → **Applications → Applications → Create Application**
2. Name: `Data App UI` (or similar)
3. Type: **Single Page Applications**
4. Click **Create**

#### Configure SPA Settings

In the application's **Settings** tab:

**Application URIs:**
- **Allowed Callback URLs**: 
  ```
  https://canton-data-ui.yourdomain.com/callback
  ```
- **Allowed Logout URLs**: 
  ```
  https://canton-data-ui.yourdomain.com
  ```
- **Allowed Web Origins**: 
  ```
  https://canton-data-ui.yourdomain.com
  ```
- **Allowed Origins (CORS)**: 
  ```
  https://canton-data-ui.yourdomain.com
  ```

**Note:** Replace `yourdomain.com` with your actual domain.

#### Advanced Settings (Optional)

- **Token Expiration**: Adjust token lifetime if needed (default: 36000 seconds)
- **Refresh Token Rotation**: Enable for enhanced security
- **Refresh Token Expiration**: Set based on your security requirements

#### Note Down SPA Credentials

- **Domain**: `your-tenant.us.auth0.com`
- **Client ID**: `abc123...` (you'll need this for frontend configuration)

### 2. Understanding Audiences (API Identifiers)

Auth0 uses "audiences" to identify which API a token is intended for. Your Canton validator should already have an audience configured during its deployment.

**Common Audience Values:**
- `https://canton.network.global` (typical for Canton Network validators)
- `https://ledger-api.yourdomain.com` (custom)

**Key Points:**
- The audience value should match what your Canton participant expects in JWT tokens
- This is the same audience used by Canton's native wallet UI
- This is typically configured as a "Custom API" in Auth0

**To Find Your Audience:**
1. Check your validator's Auth0 configuration
2. Look in validator environment variables for `AUTH0_AUDIENCE` or `LEDGER_API_AUTH_AUDIENCE`
3. Check the wallet UI configuration
4. Ask your validator administrator

**To Configure API (if needed):**
1. In Auth0 Dashboard → **Applications → APIs**
2. Find or create the API your Canton participant uses
3. Ensure your SPA application is authorized to request tokens for this API

---

## Canton User & Party Setup

For users to view data in the Data App, they must have Canton users with `can_read_as` rights for the relevant parties. This is the same setup used by Canton's native wallet.

> **Important:** If you're already using Auth0 with your Canton validator (e.g., for the Canton wallet), your users are likely already configured. **You can skip to [Verification & Testing](#verification--testing).**

### When You Need This Section

Only if you're:
- Setting up Auth0 authentication for the first time, OR  
- Granting additional users access to specific parties

If your users can already log into the Canton wallet with Auth0, they can use the Data App with the same credentials—no additional setup needed.

### Vocabulary

- **Participant User**: A user object **inside Canton** (not Auth0) whose `id` must equal the JWT token's `sub` claim
- **Party**: A Canton party identifier that can act on the ledger
- **Rights**: `can_act_as` (submit commands) and `can_read_as` (read ledger state)
- **API / Audience**: Auth0 "Custom API" identifier (e.g., `https://canton.network.global`)

> **Critical**: The Canton user ID must match the `sub` claim from the Auth0 JWT token. For Auth0 users, this is typically in the format `auth0|<user_id>` or similar, depending on the connection type

If you need to create new Canton users or grant permissions:

**1. Get an admin token with `participant_admin` privileges:**

```bash
export AUTH0_DOMAIN="your-tenant.us.auth0.com"
export AUDIENCE="https://canton.network.global"
export DOCKER_NETWORK="splice-validator_splice_validator"

# Get admin token (requires admin M2M app credentials)
ADMIN_TOKEN_JSON=$(curl -s https://$AUTH0_DOMAIN/oauth/token \
  -H 'content-type: application/json' \
  -d '{"client_id":"<ADMIN_CLIENT_ID>","client_secret":"<ADMIN_CLIENT_SECRET>","audience":"'"$AUDIENCE"'","grant_type":"client_credentials"}')

export ADMIN_TOKEN=$(echo "$ADMIN_TOKEN_JSON" | jq -r .access_token)
```

**2. Create Canton user and grant rights:**

```bash
# Get user's Auth0 ID from their JWT token (sub claim, e.g., auth0|507f1f77bcf86cd799439011)
export USER_ID="<user_auth0_id>"
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
- The Canton `USER_ID` must exactly match the `sub` claim from the user's Auth0 JWT
- Users need `can_read_as` rights to view data in the Data App
- Common Auth0 `sub` formats: `auth0|<id>`, `google-oauth2|<id>`, etc.

---

## Verification & Testing

### Test User Login and Token

The easiest way to test is to have a user log into the frontend and verify their token:

1. Navigate to the frontend URL
2. Log in with Auth0
3. Open browser developer tools → Console
4. The application should have received a JWT token

### Test Token Manually

If you need to test a user's token manually against Canton, you can extract it from the browser and test it.

### Test Canton Ledger API Access

Using a user's token, test access to Canton:

```bash
# Set to the user's JWT token (obtained from browser or Auth0)
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
3. You should be redirected to Auth0's login page
4. After successful authentication, you should be redirected back to the dashboard

If you get errors, check:
- Auth0 SPA callback URLs are correctly configured
- Browser console for detailed error messages
- Network tab for failed requests

---

## Troubleshooting Auth0 Issues

### Token Request Fails

**Symptoms**: `curl` to `/oauth/token` returns error

**Common Errors:**

1. **`invalid_client`**
   - **Cause**: Wrong client ID or client secret
   - **Solution**: Double-check credentials in Auth0 dashboard

2. **`access_denied`**
   - **Cause**: M2M app not authorized for the API/audience
   - **Solution**: In Auth0 Dashboard → Applications → Your M2M App → APIs tab → Authorize the API

3. **`invalid_request`**
   - **Cause**: Missing or malformed request parameters
   - **Solution**: Ensure `client_id`, `client_secret`, `audience`, and `grant_type` are all provided

### Canton Returns UNAUTHENTICATED

**Symptoms**: gRPC calls return `UNAUTHENTICATED` error

**Solutions:**
1. Verify token is not expired:
   ```bash
   echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .exp | xargs -I{} date -r {}
   ```
2. Check audience matches Canton's expected audience:
   ```bash
   echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .aud
   ```
3. Verify Canton participant has Auth0 JWT validation configured
4. Check Canton logs for JWT validation errors

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
3. Verify user ID exactly matches `<CLIENT_ID>@clients`
4. Ensure rights are granted for the correct party

### Frontend Redirect Loop

**Symptoms**: Frontend continuously redirects to Auth0 and back

**Solutions:**
1. Check SPA callback URL in Auth0 matches frontend URL exactly
2. Verify `VITE_AUTH0_REDIRECT_URI` in frontend config
3. Check browser console for specific error messages
4. Clear browser cookies and try again

### Frontend Shows Auth0 Error Page

**Symptoms**: Auth0 shows error after login attempt

**Common Errors:**

1. **`access_denied`**
   - **Cause**: User not authorized for the application
   - **Solution**: Check Auth0 user permissions or enable "Auto-assign" in application settings

2. **`unauthorized`**
   - **Cause**: Callback URL mismatch
   - **Solution**: Ensure callback URL in Auth0 exactly matches frontend URL

3. **`invalid_request`**
   - **Cause**: Missing required parameters
   - **Solution**: Check frontend Auth0 configuration for all required fields

### Token Sub Doesn't Match User ID

**Symptoms**: Canton user exists but token still fails authentication

**Solutions:**
1. Decode token and check `sub` claim:
   ```bash
   echo "$ACCESS_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .sub
   ```
2. Ensure it exactly matches the Canton user ID
3. The `sub` claim format varies by Auth0 connection type:
   - `auth0|<id>` for Auth0 database users
   - `google-oauth2|<id>` for Google
   - Check the actual token to see the exact format
4. Recreate Canton user with correct ID if mismatch

### CORS Errors in Browser

**Symptoms**: Browser console shows CORS errors when calling Auth0

**Solutions:**
1. In Auth0 Dashboard → Applications → Your SPA → Settings
2. Add frontend URL to:
   - Allowed Web Origins
   - Allowed Origins (CORS)
3. Ensure URLs are exact (including protocol and no trailing slash)

