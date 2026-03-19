"""
Wiseling Load Test — Locust
Simulates realistic user flows across all services:
  - Auth: register, login, validate token
  - Wallet: check balances, ledger, transfers
  - Conversion: create FX conversions, list, check rates
  - Withdrawal: P2P transfers, list sent/received
"""

import random
import string
import uuid
from locust import HttpUser, task, between


# ─── Helpers ──────────────────────────────────────────────────────────────────

def random_email():
    suffix = ''.join(random.choices(string.ascii_lowercase + string.digits, k=8))
    return f"locust_{suffix}@wiseling-test.com"


def random_password():
    return "Locust@123!"


def random_account_number():
    """Generate a plausible account number format."""
    return ''.join(random.choices(string.digits, k=10))


CURRENCIES = ["USD", "NZD", "EUR", "GBP", "AUD"]


# ─── Auth User ────────────────────────────────────────────────────────────────

class AuthUser(HttpUser):
    """
    Simulates auth service load:
    - Heavy on login (most common operation)
    - Some registrations
    - Token validation (internal but testable)
    """
    host = "http://auth-service:8000"
    wait_time = between(1, 3)
    weight = 3  # 3x more auth traffic than other services

    def on_start(self):
        """Register and login on start to get a token."""
        self.email = random_email()
        self.password = random_password()
        self.token = None
        self._register()
        self._login()

    def _register(self):
        with self.client.post(
            "/api/v1/auth/register",
            json={"email": self.email, "password": self.password},
            catch_response=True,
            name="/api/v1/auth/register"
        ) as resp:
            if resp.status_code not in (201, 400):  # 400 = already exists, fine
                resp.failure(f"Unexpected status: {resp.status_code}")

    def _login(self):
        with self.client.post(
            "/api/v1/auth/login",
            data={"username": self.email, "password": self.password},
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            catch_response=True,
            name="/api/v1/auth/login"
        ) as resp:
            if resp.status_code == 200:
                self.token = resp.json().get("access_token")
            else:
                resp.failure(f"Login failed: {resp.status_code}")

    @task(5)
    def login(self):
        """Most common operation — users logging in."""
        self._login()

    @task(2)
    def get_me(self):
        """Get current user profile."""
        if not self.token:
            return
        with self.client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {self.token}"},
            catch_response=True,
            name="/api/v1/auth/me"
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Get me failed: {resp.status_code}")

    @task(1)
    def register_new_user(self):
        """Simulate new user registrations."""
        email = random_email()
        with self.client.post(
            "/api/v1/auth/register",
            json={"email": email, "password": random_password()},
            catch_response=True,
            name="/api/v1/auth/register"
        ) as resp:
            if resp.status_code not in (201, 400):
                resp.failure(f"Register failed: {resp.status_code}")

    @task(1)
    def invalid_login(self):
        """Simulate failed logins — triggers 401 alerts."""
        with self.client.post(
            "/api/v1/auth/login",
            data={"username": "nonexistent@test.com", "password": "wrongpassword"},
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            catch_response=True,
            name="/api/v1/auth/login [invalid]"
        ) as resp:
            if resp.status_code == 401:
                resp.success()  # expected
            else:
                resp.failure(f"Expected 401, got: {resp.status_code}")


# ─── Wallet User ──────────────────────────────────────────────────────────────

class WalletUser(HttpUser):
    """
    Simulates wallet service load:
    - Balance checks (most frequent)
    - Ledger reads
    - Transfer history
    """
    host = "http://wallet-service:8001"
    wait_time = between(2, 5)
    weight = 4  # Most common — users checking balances

    def on_start(self):
        self.email = random_email()
        self.password = random_password()
        self.token = None
        self._register_and_login()

    def _register_and_login(self):
        self.client.post(
            "http://auth-service:8000/api/v1/auth/register",
            json={"email": self.email, "password": self.password},
        )
        resp = self.client.post(
            "http://auth-service:8000/api/v1/auth/login",
            data={"username": self.email, "password": self.password},
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if resp.status_code == 200:
            self.token = resp.json().get("access_token")

    def _auth_headers(self):
        return {"Authorization": f"Bearer {self.token}"}

    @task(5)
    def check_balances(self):
        """Most frequent — users checking wallet balances."""
        if not self.token:
            return
        with self.client.get(
            "/api/v1/wallet/balances",
            headers=self._auth_headers(),
            catch_response=True,
            name="/api/v1/wallet/balances"
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Balance check failed: {resp.status_code}")

    @task(2)
    def check_ledger(self):
        """Transaction history."""
        if not self.token:
            return
        with self.client.get(
            "/api/v1/wallet/ledger",
            headers=self._auth_headers(),
            catch_response=True,
            name="/api/v1/wallet/ledger"
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Ledger failed: {resp.status_code}")

    @task(2)
    def check_transfers(self):
        """Transfer history."""
        if not self.token:
            return
        with self.client.get(
            "/api/v1/wallet/transfers",
            headers=self._auth_headers(),
            catch_response=True,
            name="/api/v1/wallet/transfers"
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Transfers failed: {resp.status_code}")


# ─── Conversion User ──────────────────────────────────────────────────────────

class ConversionUser(HttpUser):
    """
    Simulates FX conversion load:
    - Rate checks (frequent, no auth needed)
    - FX conversions (write operations)
    - Conversion history
    """
    host = "http://conversion-service:8002"
    wait_time = between(3, 8)
    weight = 2

    def on_start(self):
        self.email = random_email()
        self.password = random_password()
        self.token = None
        self._register_and_login()

    def _register_and_login(self):
        self.client.post(
            "http://auth-service:8000/api/v1/auth/register",
            json={"email": self.email, "password": self.password},
        )
        resp = self.client.post(
            "http://auth-service:8000/api/v1/auth/login",
            data={"username": self.email, "password": self.password},
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if resp.status_code == 200:
            self.token = resp.json().get("access_token")

    def _auth_headers(self):
        return {"Authorization": f"Bearer {self.token}"}

    @task(4)
    def check_rates(self):
        """Rate checks — no auth required, high frequency."""
        with self.client.get(
            "/api/v1/conversions/rates",
            catch_response=True,
            name="/api/v1/conversions/rates"
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Rates failed: {resp.status_code}")

    @task(2)
    def create_conversion(self):
        """FX conversion — write operation, triggers outbox + SQS."""
        if not self.token:
            return
        from_currency = random.choice(CURRENCIES)
        to_currency = random.choice([c for c in CURRENCIES if c != from_currency])
        with self.client.post(
            "/api/v1/conversions",
            headers=self._auth_headers(),
            json={
                "from_currency": from_currency,
                "to_currency": to_currency,
                "amount": round(random.uniform(10, 500), 2),
                "idempotency_key": str(uuid.uuid4())
            },
            catch_response=True,
            name="/api/v1/conversions [create]"
        ) as resp:
            if resp.status_code not in (201, 400, 422):
                resp.failure(f"Conversion failed: {resp.status_code}")

    @task(2)
    def list_conversions(self):
        """List user conversions."""
        if not self.token:
            return
        with self.client.get(
            "/api/v1/conversions",
            headers=self._auth_headers(),
            catch_response=True,
            name="/api/v1/conversions [list]"
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"List conversions failed: {resp.status_code}")


# ─── Withdrawal User ──────────────────────────────────────────────────────────

class WithdrawalUser(HttpUser):
    """
    Simulates P2P transfer load:
    - Transfer creation (write, triggers outbox + SQS)
    - List sent/received transfers
    """
    host = "http://withdrawal-service:8003"
    wait_time = between(5, 15)  # P2P transfers less frequent than balance checks
    weight = 1

    def on_start(self):
        self.email = random_email()
        self.password = random_password()
        self.token = None
        self._register_and_login()

    def _register_and_login(self):
        self.client.post(
            "http://auth-service:8000/api/v1/auth/register",
            json={"email": self.email, "password": self.password},
        )
        resp = self.client.post(
            "http://auth-service:8000/api/v1/auth/login",
            data={"username": self.email, "password": self.password},
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if resp.status_code == 200:
            self.token = resp.json().get("access_token")

    def _auth_headers(self):
        return {"Authorization": f"Bearer {self.token}"}

    @task(3)
    def list_withdrawals(self):
        """List sent transfers."""
        if not self.token:
            return
        with self.client.get(
            "/api/v1/withdrawals",
            headers=self._auth_headers(),
            catch_response=True,
            name="/api/v1/withdrawals [list]"
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"List withdrawals failed: {resp.status_code}")

    @task(2)
    def list_received(self):
        """List received transfers."""
        if not self.token:
            return
        with self.client.get(
            "/api/v1/withdrawals/received",
            headers=self._auth_headers(),
            catch_response=True,
            name="/api/v1/withdrawals/received"
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"List received failed: {resp.status_code}")

    @task(1)
    def create_transfer(self):
        """P2P transfer — most expensive operation, triggers full outbox flow."""
        if not self.token:
            return
        with self.client.post(
            "/api/v1/withdrawals/transfer",
            headers=self._auth_headers(),
            json={
                "currency": random.choice(["USD", "NZD"]),
                "amount": round(random.uniform(1, 50), 2),
                "idempotency_key": str(uuid.uuid4()),
                "to_account_number": random_account_number()
            },
            catch_response=True,
            name="/api/v1/withdrawals/transfer"
        ) as resp:
            # 404 expected if recipient doesn't exist — that's fine
            if resp.status_code not in (201, 404, 400, 422):
                resp.failure(f"Transfer failed: {resp.status_code}")
