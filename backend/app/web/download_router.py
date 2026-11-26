"""``GET /download/afterme.apk``: the tester build of the Android app, for phones that install
it outside Play. The "Update AfterMe" screen of the app opens this address. Nothing about any
person is involved; the file is whatever ``AFTERME_APK_DOWNLOAD_PATH`` names."""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Request
from starlette.responses import FileResponse, Response

from app.core.config import Settings

router = APIRouter(tags=["web"], include_in_schema=False)

APK_MEDIA_TYPE = "application/vnd.android.package-archive"


@router.get("/download/afterme.apk")
def download_apk(request: Request) -> Response:
    settings: Settings = request.app.state.services.settings
    path = Path(settings.apk_download_path).expanduser() if settings.apk_download_path else None
    if path is None or not path.is_file():
        return Response(status_code=404)
    return FileResponse(
        path,
        media_type=APK_MEDIA_TYPE,
        filename="AfterMe.apk",
        headers={"Cache-Control": "no-store"},
    )
