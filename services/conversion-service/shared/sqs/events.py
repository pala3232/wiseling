"""
All SQS event type constants. Import from here — never hardcode strings.
"""

# Conversion events
CONVERSION_REQUESTED = "conversion.requested"   # conversion-service → wallet-service
CONVERSION_SETTLED = "conversion.settled"        # wallet-service → conversion-service

# Withdrawal events
WITHDRAWAL_REQUESTED = "withdrawal.requested"    # withdrawal-service → wallet-service
WITHDRAWAL_DEBITED = "withdrawal.debited"        # wallet-service → withdrawal-service processor
WITHDRAWAL_COMPLETED = "withdrawal.completed"    # processor → withdrawal-service
WITHDRAWAL_FAILED = "withdrawal.failed"          # processor → withdrawal-service
