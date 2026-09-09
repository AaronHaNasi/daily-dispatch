#!/usr/bin/env python3
"""Cloud Run Job entrypoint: build the daily EPUB and upload it to Google Drive."""

import json
import os
import subprocess
import sys
from datetime import date, datetime, timezone
from pathlib import Path

from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

RECIPE_PATH = Path(__file__).parent / "daily-digest.recipe"
DRIVE_SCOPES = ["https://www.googleapis.com/auth/drive.file"]
TOKEN_URI = "https://oauth2.googleapis.com/token"


def build_epub(output_path: Path) -> None:
    subprocess.run(
        ["ebook-convert", str(RECIPE_PATH), str(output_path)],
        check=True,
    )


def drive_client():
    creds_json = os.environ["GDRIVE_OAUTH_CREDENTIALS"]
    creds_info = json.loads(creds_json)
    creds = Credentials(
        token=None,
        refresh_token=creds_info["refresh_token"],
        client_id=creds_info["client_id"],
        client_secret=creds_info["client_secret"],
        token_uri=TOKEN_URI,
        scopes=DRIVE_SCOPES,
    )
    return build("drive", "v3", credentials=creds)


def upload_epub(service, path: Path, folder_id: str) -> str:
    metadata = {"name": path.name, "parents": [folder_id]}
    media = MediaFileUpload(str(path), mimetype="application/epub+zip")
    uploaded = service.files().create(body=metadata, media_body=media, fields="id").execute()
    return uploaded["id"]

def clean_epub(service, folder_id: str) -> None:
    """Remove EPUB files after a week to avoid filling up Google Drive storage."""
    # Get list of files
    results = service.files().list(
        q=f"'{folder_id}' in parents and mimeType='application/epub+zip'",
        fields="files(id, name, createdTime)",
    ).execute()
    for file in results.get("files", []):
        created_time = datetime.fromisoformat(file["createdTime"].replace("Z", "+00:00"))
        if (datetime.now(timezone.utc) - created_time).days > 7:
            print(f"[{datetime.now(timezone.utc).isoformat()}] Deleting old EPUB {file['name']} (id={file['id']})")
            service.files().delete(fileId=file["id"]).execute()

def main() -> int:
    folder_id = os.environ["GDRIVE_FOLDER_ID"]

    today = date.today().isoformat()
    output_path = Path(f"/tmp/daily-digest-{today}.epub")

    print(f"[{datetime.now(timezone.utc).isoformat()}] Converting recipe -> {output_path}")
    build_epub(output_path)

    print(f"[{datetime.now(timezone.utc).isoformat()}] Uploading to Drive folder {folder_id}")
    service = drive_client()
    file_id = upload_epub(service, output_path, folder_id)
    clean_epub(service, folder_id)
    print(f"[{datetime.now(timezone.utc).isoformat()}] Uploaded file id={file_id}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as e:
        print(f"ebook-convert failed with exit code {e.returncode}", file=sys.stderr)
        sys.exit(e.returncode)
    except Exception as e:
        print(f"generate-dispatch failed: {e}", file=sys.stderr)
        sys.exit(1)
