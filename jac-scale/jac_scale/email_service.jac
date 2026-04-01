"""SMTP email service for notifications (password reset, verification, etc.)."""
import from typing { Any }

obj EmailService {
    has _smtp_host: str,
        _smtp_port: int,
        _smtp_username: str,
        _smtp_password: str,
        _from_email: str,
        _use_tls: bool;

    """Create an EmailService from jac.toml configuration."""
    static def from_config -> EmailService;

    """Send an email. Returns True on success, False on failure."""
    def send_email(
        to: str,
        subject: str,
        body: str,
        html_body: str | None = None
    ) -> bool;

    """Check if SMTP is configured (host and from_email are set)."""
    def is_configured -> bool;
}
