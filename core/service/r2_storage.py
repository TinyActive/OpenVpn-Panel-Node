import os
import subprocess
import requests
from typing import Optional

import boto3
from botocore.exceptions import ClientError

from logger import logger
from config import settings


def get_public_ip() -> Optional[str]:
    """Get server public IP address"""
    try:
        result = subprocess.run(
            ["curl", "-s", "-4", "ifconfig.me"],
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except Exception as e:
        logger.error(f"Error getting public IP: {e}")
    
    try:
        result = subprocess.run(
            ["ip", "addr", "show"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            import re
            match = re.search(r'inet (\d+\.\d+\.\d+\.\d+)', result.stdout)
            if match:
                ip = match.group(1)
                if not ip.startswith('127.'):
                    return ip
    except Exception as e:
        logger.error(f"Error getting IP from ip command: {e}")
    
    return None


def get_r2_endpoint() -> Optional[str]:
    """Build R2 S3 endpoint URL"""
    if settings.r2_endpoint:
        return settings.r2_endpoint
    if settings.r2_account_id:
        return f"https://{settings.r2_account_id}.r2.cloudflarestorage.com"
    return None


def get_s3_client():
    """Get boto3 S3 client configured for Cloudflare R2"""
    endpoint = get_r2_endpoint()
    if not endpoint:
        logger.error("R2 endpoint not configured")
        return None
    
    if not settings.r2_access_key_id or not settings.r2_secret_access_key:
        logger.error("R2 credentials not configured")
        return None
    
    try:
        client = boto3.client(
            "s3",
            endpoint_url=endpoint,
            aws_access_key_id=settings.r2_access_key_id,
            aws_secret_access_key=settings.r2_secret_access_key,
        )
        return client
    except Exception as e:
        logger.error(f"Error creating R2 client: {e}")
        return None


def upload_ovpn_to_r2(local_path: str, username: str) -> bool:
    """
    Upload .ovpn file to R2 bucket
    
    Args:
        local_path: Local path to .ovpn file
        username: Username for object key naming
        
    Returns:
        True if upload successful, False otherwise
    """
    if not settings.r2_bucket_name:
        logger.error("R2 bucket name not configured")
        return False
    
    client = get_s3_client()
    if not client:
        return False
    
    public_ip = get_public_ip()
    if not public_ip:
        logger.error("Could not determine public IP for R2 object key")
        return False
    
    object_key = f"{public_ip}/{username}.ovpn"
    
    try:
        client.upload_file(local_path, settings.r2_bucket_name, object_key)
        logger.info(f"Uploaded {local_path} to R2 as {object_key}")
        return True
    except ClientError as e:
        logger.error(f"R2 upload error: {e}")
        return False
    except Exception as e:
        logger.error(f"Unknown R2 upload error: {e}")
        return False


def download_ovpn_from_r2(username: str, local_path: str) -> bool:
    """
    Download .ovpn file from R2 via HTTP GET with token
    
    Args:
        username: Username for object key
        local_path: Local path to save downloaded file
        
    Returns:
        True if download successful, False otherwise
    """
    public_ip = get_public_ip()
    if not public_ip:
        logger.error("Could not determine public IP for R2 download")
        return False
    
    public_url = f"https://{settings.r2_public_base_url}/{public_ip}/{username}.ovpn?token={settings.r2_download_token}"
    
    try:
        resp = requests.get(public_url, stream=True, timeout=30)
        if resp.status_code == 200:
            os.makedirs(os.path.dirname(local_path), exist_ok=True)
            with open(local_path, "wb") as f:
                for chunk in resp.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)
            logger.info(f"Downloaded {username}.ovpn from R2 to {local_path}")
            return True
        else:
            logger.error(f"R2 download failed with status {resp.status_code}")
            return False
    except requests.exceptions.RequestException as e:
        logger.error(f"R2 download request error: {e}")
        return False
    except Exception as e:
        logger.error(f"Unknown R2 download error: {e}")
        return False


def delete_ovpn_from_r2(username: str) -> bool:
    """
    Delete .ovpn file from R2 bucket
    
    Args:
        username: Username for object key
        
    Returns:
        True if deletion successful, False otherwise
    """
    if not settings.r2_bucket_name:
        logger.error("R2 bucket name not configured")
        return False
    
    client = get_s3_client()
    if not client:
        return False
    
    public_ip = get_public_ip()
    if not public_ip:
        logger.error("Could not determine public IP for R2 object key")
        return False
    
    object_key = f"{public_ip}/{username}.ovpn"
    
    try:
        client.delete_object(Bucket=settings.r2_bucket_name, Key=object_key)
        logger.info(f"Deleted {object_key} from R2")
        return True
    except ClientError as e:
        logger.error(f"R2 deletion error: {e}")
        return False
    except Exception as e:
        logger.error(f"Unknown R2 deletion error: {e}")
        return False
