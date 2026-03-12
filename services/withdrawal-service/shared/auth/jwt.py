"""
Shared JWT validation used by all services.
Each service imports this to validate tokens issued by auth-service.
"""
import os
from jose import JWTError, jwt

SECRET_KEY = os.getenv("JWT_SECRET_KEY", "change-me-in-production")
ALGORITHM = "HS256"


def decode_token(token: str) -> str | None:
    """Returns the user_id (sub) from a valid token, or None."""
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        return payload.get("sub")
    except JWTError:
        return None


def require_user_id(token: str) -> str:
    """Raises ValueError if token is invalid."""
    user_id = decode_token(token)
    if not user_id:
        raise ValueError("Invalid or expired token")
    return user_id
