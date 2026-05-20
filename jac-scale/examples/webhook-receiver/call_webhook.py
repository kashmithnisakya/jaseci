"""Sign and call the PaymentReceived webhook.

Usage:
    python call_webhook.py <api_key> <signing_secret> [base_url]

The api_key and signing_secret come from the /api-key/create response;
the signing_secret is shown only once, store it out of band.
"""

import hashlib
import hmac
import json
import sys
import time

import requests


def main() -> None:
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)

    api_key = sys.argv[1]
    signing_secret = sys.argv[2]
    base_url = sys.argv[3] if len(sys.argv) > 3 else "http://localhost:8000"

    body = json.dumps(
        {
            "payment_id": "PAY-12345",
            "order_id": "ORD-67890",
            "amount": 99.99,
            "currency": "USD",
        }
    ).encode("utf-8")
    ts = str(int(time.time()))
    signed = f"{ts}.".encode() + body
    sig = hmac.new(signing_secret.encode("utf-8"), signed, hashlib.sha256).hexdigest()

    resp = requests.post(
        f"{base_url}/webhook/PaymentReceived",
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-API-Key": api_key,
            "X-Webhook-Signature": sig,
            "X-Webhook-Timestamp": ts,
        },
        timeout=10,
    )
    print(resp.status_code, resp.text)


if __name__ == "__main__":
    main()
