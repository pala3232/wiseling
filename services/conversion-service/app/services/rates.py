"""
Pluggable FX rates provider.
Switch via RATES_PROVIDER env var: "static" or "openexchangerates".
Add new providers by implementing RatesProvider and registering in get_provider().
"""
from abc import ABC, abstractmethod
from decimal import Decimal
import httpx
from app.core.config import settings


class RatesProvider(ABC):
    @abstractmethod
    async def get_rate(self, from_currency: str, to_currency: str) -> Decimal:
        pass

    @abstractmethod
    async def list_rates(self) -> dict:
        pass


class StaticRatesProvider(RatesProvider):
    """Hardcoded rates — no external dependency. Good for dev/testing."""

    async def get_rate(self, from_currency: str, to_currency: str) -> Decimal:
        if from_currency == to_currency:
            return Decimal("1")
        key = f"{from_currency}/{to_currency}"
        rate = settings.FX_RATES.get(key)
        if not rate:
            raise ValueError(f"No rate for {key}")
        return Decimal(str(rate))

    async def list_rates(self) -> dict:
        return settings.FX_RATES


class OpenExchangeRatesProvider(RatesProvider):
    """Live rates from openexchangerates.org — set OPEN_EXCHANGE_RATES_APP_ID."""
    BASE = "https://openexchangerates.org/api"

    async def _fetch_rates(self) -> dict:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                f"{self.BASE}/latest.json",
                params={"app_id": settings.OPEN_EXCHANGE_RATES_APP_ID, "base": "USD"},
            )
            r.raise_for_status()
            return r.json()["rates"]

    async def get_rate(self, from_currency: str, to_currency: str) -> Decimal:
        if from_currency == to_currency:
            return Decimal("1")
        rates = await self._fetch_rates()
        if from_currency == "USD":
            return Decimal(str(rates[to_currency]))
        # Cross rate via USD
        from_usd = Decimal(str(rates[from_currency]))
        to_usd = Decimal(str(rates[to_currency]))
        return to_usd / from_usd

    async def list_rates(self) -> dict:
        return await self._fetch_rates()


def get_provider() -> RatesProvider:
    if settings.RATES_PROVIDER == "openexchangerates":
        return OpenExchangeRatesProvider()
    return StaticRatesProvider()
