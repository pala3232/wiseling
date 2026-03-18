import httpx
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.db.session import get_db
from app.models.user import User
from app.schemas.auth import RegisterRequest, TokenResponse, UserResponse, ValidateTokenRequest, ValidateTokenResponse
from app.core.security import hash_password, verify_password, create_access_token, decode_token
from app.core.dependencies import get_current_user
from app.core.config import settings

router = APIRouter(prefix="/auth", tags=["auth"])

@router.get("/health")
async def health():
    return {"service": "auth", "status": "ok"}

@router.post("/register", response_model=UserResponse, status_code=201)
async def register(body: RegisterRequest, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.email == body.email))
    if result.scalar_one_or_none():
        raise HTTPException(status_code=400, detail="Email already registered")

    user = User(email=body.email, hashed_password=hash_password(body.password))
    db.add(user)
    await db.commit()
    await db.refresh(user)

    # Tell wallet-service to create starter wallets for this user
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            await client.post(
                f"{settings.WALLET_SERVICE_URL}/internal/wallets/init",
                json={"user_id": user.id},
            )
    except Exception:
        # Non-fatal: wallet-service may retry or operator can seed manually
        pass

    return user


@router.post("/login", response_model=TokenResponse)
async def login(form: OAuth2PasswordRequestForm = Depends(), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.email == form.username))
    user = result.scalar_one_or_none()
    if not user or not verify_password(form.password, user.hashed_password):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")
    return TokenResponse(access_token=create_access_token(user.id))


@router.get("/me", response_model=UserResponse)
async def me(user: User = Depends(get_current_user)):
    return user


@router.post("/validate", response_model=ValidateTokenResponse)
async def validate_token(body: ValidateTokenRequest):
    """Internal endpoint — other services call this to validate a JWT."""
    user_id = decode_token(body.token)
    return ValidateTokenResponse(valid=user_id is not None, user_id=user_id)


@router.get("/lookup/{account_number}", include_in_schema=False)
async def lookup_account(account_number: str, db: AsyncSession = Depends(get_db)):
    """Internal — resolve account number to user email (for recipient preview)."""
    result = await db.execute(select(User).where(User.account_number == account_number))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="Account not found")
    return {"user_id": user.id, "email": user.email, "account_number": user.account_number}