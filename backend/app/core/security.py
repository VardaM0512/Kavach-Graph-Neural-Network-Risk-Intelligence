"""JWT auth + password hashing.

Minimal, dependency-light auth so the API has a real login flow. In production
back the user store with Postgres (or Firebase Auth) — the token contract stays
the same.
"""
from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer

from .config import get_settings

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login", auto_error=False)

# --- password hashing (passlib if available, else a salted sha256 fallback) ---
try:
    from passlib.context import CryptContext
    # pbkdf2_sha256 is pure-Python in passlib — no native bcrypt backend needed,
    # which avoids bcrypt>=4.1 / passlib version-detection incompatibilities.
    _pwd = CryptContext(schemes=["pbkdf2_sha256"], deprecated="auto")

    def hash_password(p: str) -> str:
        return _pwd.hash(p)

    def verify_password(p: str, h: str) -> bool:
        return _pwd.verify(p, h)
except Exception:  # pragma: no cover
    import hashlib
    import os

    def hash_password(p: str) -> str:
        salt = os.urandom(16).hex()
        return salt + "$" + hashlib.sha256((salt + p).encode()).hexdigest()

    def verify_password(p: str, h: str) -> bool:
        try:
            salt, digest = h.split("$", 1)
            return hashlib.sha256((salt + p).encode()).hexdigest() == digest
        except Exception:
            return False


def create_access_token(subject: str, extra: dict | None = None) -> str:
    from jose import jwt
    s = get_settings()
    now = datetime.now(timezone.utc)
    payload = {"sub": subject, "iat": int(now.timestamp()),
               "exp": now + timedelta(minutes=s.access_token_expire_minutes)}
    if extra:
        payload.update(extra)
    return jwt.encode(payload, s.jwt_secret, algorithm=s.jwt_algorithm)


def decode_token(token: str) -> dict:
    from jose import jwt, JWTError
    s = get_settings()
    try:
        return jwt.decode(token, s.jwt_secret, algorithms=[s.jwt_algorithm])
    except JWTError as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"invalid token: {e}")


async def get_current_user(token: str | None = Depends(oauth2_scheme)) -> dict:
    if not token:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "not authenticated")
    payload = decode_token(token)
    return {"user_id": payload.get("sub"), "email": payload.get("email")}
