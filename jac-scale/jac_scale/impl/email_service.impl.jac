"""SMTP email service implementation."""
import smtplib;
import logging;
import from email.mime.text { MIMEText }
import from email.mime.multipart { MIMEMultipart }
import from jac_scale.config_loader { get_scale_config }

glob logger = logging.getLogger(__name__);

"""Create an EmailService from jac.toml [plugins.scale.email] configuration."""
impl EmailService.from_config -> EmailService {
    config = get_scale_config().get_email_config();
    return EmailService(
        _smtp_host=config['smtp_host'],
        _smtp_port=config['smtp_port'],
        _smtp_username=config['smtp_username'],
        _smtp_password=config['smtp_password'],
        _from_email=config['from_email'],
        _use_tls=config['use_tls']
    );
}

"""Check if SMTP is configured (host and from_email are set)."""
impl EmailService.is_configured -> bool {
    return bool(self._smtp_host and self._from_email);
}

"""Send an email via SMTP. Returns True on success, False on failure."""
impl EmailService.send_email(
    to: str,
    subject: str,
    body: str,
    html_body: str | None = None
) -> bool {
    if not self.is_configured() {
        logger.warning("Email not configured. Skipping send.");
        return False;
    }
    try {
        msg = MIMEMultipart('alternative');
        msg['Subject'] = subject;
        msg['From'] = self._from_email;
        msg['To'] = to;
        msg.attach(MIMEText(body, 'plain'));
        if html_body {
            msg.attach(MIMEText(html_body, 'html'));
        }
        with smtplib.SMTP(self._smtp_host, self._smtp_port) as server {
            if self._use_tls {
                server.starttls();
            }
            if self._smtp_username {
                server.login(self._smtp_username, self._smtp_password);
            }
            server.sendmail(self._from_email, to, msg.as_string());
        }
        logger.info(f"Email sent to {to}: {subject}");
        return True;
    } except Exception as e {
        logger.error(f"Failed to send email to {to}: {e}");
        return False;
    }
}
