"""In-memory fake emailer for tests.

The /user/add-identity and /user/forgot-password flows need a working emailer
to issue verification + reset tokens. This fake collects every send into a
shared module-level list so tests can assert on what was sent (and pull the
token out of the body).

Loaded via `provider = "test_emailer_fake:FakeEmailer"` in jac.toml.
"""

from __future__ import annotations

from jac_scale.abstractions.emailer import Emailer

# Shared mailbox — tests inspect and clear this between cases.
SENT: list[dict] = []


class FakeEmailer(Emailer):
    def __init__(
        self,
        config: dict | None = None,
        from_address: str = "",
        enabled: bool = True,
    ) -> None:
        self.config = config or {}
        self.from_address = from_address
        self.enabled = enabled

    def is_ready(self) -> bool:
        return True

    def send_email(
        self,
        to_addr: str,
        subject: str,
        body_text: str,
        body_html: str | None = None,
        from_addr: str | None = None,
    ) -> bool:
        SENT.append(
            {
                "to": to_addr,
                "subject": subject,
                "body_text": body_text,
                "body_html": body_html,
                "from": from_addr or self.from_address,
            }
        )
        return True
