#!/usr/bin/env python3
"""One-time local script: mint a Google Drive refresh token for the Cloud Run job.

Run this once after creating the OAuth Desktop client in the GCP Console
(see README.md). It opens a browser for consent, then prints a JSON blob
to feed into `gcloud secrets versions add`.

Usage:
    pip install -r requirements-dev.txt
    python3 oauth_setup.py --client-id ... --client-secret ...
"""

import argparse
import json
import os
import sys

# Google's consent server sometimes returns a broader scope set than
# requested (e.g. silently adds openid/userinfo.email). Without this,
# oauthlib's strict scope-matching raises inside the local callback handler,
# which surfaces to the browser as a bare 500 after clicking "Allow".
os.environ.setdefault("OAUTHLIB_RELAX_TOKEN_SCOPE", "1")

from google_auth_oauthlib.flow import InstalledAppFlow

DRIVE_SCOPES = ["https://www.googleapis.com/auth/drive.file"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--client-secret", required=True)
    args = parser.parse_args()

    client_config = {
        "installed": {
            "client_id": args.client_id,
            "client_secret": args.client_secret,
            "auth_uri": "https://accounts.google.com/o/oauth2/auth",
            "token_uri": "https://oauth2.googleapis.com/token",
            "redirect_uris": ["http://localhost"],
        }
    }

    flow = InstalledAppFlow.from_client_config(client_config, scopes=DRIVE_SCOPES)
    # prompt=consent forces Google to issue a refresh token even on repeat runs
    # for the same account/client.
    creds = flow.run_local_server(port=0, access_type="offline", prompt="consent")

    if not creds.refresh_token:
        print(
            "No refresh token returned. Revoke prior access at "
            "https://myaccount.google.com/permissions and re-run.",
            file=sys.stderr,
        )
        return 1

    secret_payload = {
        "client_id": args.client_id,
        "client_secret": args.client_secret,
        "refresh_token": creds.refresh_token,
    }

    print("\nRefresh token minted. Store it in Secret Manager with:\n")
    print(
        "  printf '%s' '" + json.dumps(secret_payload) + "' | \\\n"
        "    gcloud secrets versions add gdrive-oauth-credentials --data-file=-\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
