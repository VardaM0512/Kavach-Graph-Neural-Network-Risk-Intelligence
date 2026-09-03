"""Auth routes — register + login issuing JWTs.

Uses an in-memory user store seeded with a demo account so the flow works out of
the box. Swap `_USERS` for a Postgres-backed repository (or Firebase Auth) in
production; the token contract is unchanged.
"""
from fastapi import APIRouter, HTTPException, status

from ..schemas import LoginRequest, RegisterRequest, TokenResponse
from ..core.security import hash_password, verify_password, create_access_token

router = APIRouter(prefix="/auth", tags=["auth"])

# demo user store: email -> {password_hash, name}
_USERS: dict[str, dict] = {
    "demo@kavach.ai": {"password_hash": hash_password("demo1234"), "name": "Demo Analyst"},
}


@router.post("/register", response_model=TokenResponse)
def register(req: RegisterRequest):
    if req.email in _USERS:
        raise HTTPException(status.HTTP_409_CONFLICT, "email already registered")
    _USERS[req.email] = {"password_hash": hash_password(req.password), "name": req.name}
    token = create_access_token(req.email, {"email": req.email})
    return TokenResponse(access_token=token, user={"email": req.email, "name": req.name})


@router.post("/login", response_model=TokenResponse)
def login(req: LoginRequest):
    user = _USERS.get(req.email)
    if not user or not verify_password(req.password, user["password_hash"]):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid credentials")
    token = create_access_token(req.email, {"email": req.email})
    return TokenResponse(access_token=token, user={"email": req.email, "name": user["name"]})
