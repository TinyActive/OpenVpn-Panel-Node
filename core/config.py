import os
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    service_port: int = 9090
    api_key: str
    debug: str = "WARNING"
    doc: bool = False

    # Cloudflare R2 Storage Settings
    r2_access_key_id: str | None = None
    r2_secret_access_key: str | None = None
    r2_bucket_name: str | None = None
    r2_endpoint: str | None = None
    r2_account_id: str | None = None
    r2_public_base_url: str = "api.openvpn.panel"
    r2_download_token: str = "8638b5a1-77df-4d24-8253-58977fa508a4"

    class Config:
        env_file = os.path.join(os.path.dirname(__file__), "../.env")


settings = Settings()
