"""User identity & password-reset endpoints.

- POST /user/add-identity     (auth) — attach a new identity (e.g. email) to the
                              calling user. Email identities trigger a
                              verification mail and start unverified.
- POST /user/verify-identity         — consume a verification token and flip the
                              matching identity to verified=True.
- POST /user/forgot-password         — issue a one-time reset token to the email
                              address tied to the identity, if any. Always
                              returns 200 (never leaks existence).
- POST /user/reset-password          — consume a reset token and set a new password.
"""

import from jac_scale.auth_tokens { AuthTokenStore }

# ============================================================================
# /user/add-identity  (requires Bearer token)
# ============================================================================
impl JacAPIServerAuth.register_add_identity_endpoint -> None {
    async def add_identity_handler(
        request: Request, body_data: AddIdentityRequest
    ) -> TransportResponse {
        authorization = request.headers.get('Authorization');
        user_id = extract_bearer_token(authorization, self.user_manager);
        if not user_id {
            return TransportResponse.fail(
                code='UNAUTHORIZED',
                message='Invalid or expired token',
                meta=Meta(extra={'http_status': 401})
            );
        }
        identity = body_data.identity.model_dump(mode='json');
        id_type = identity.get('type', '');
        raw_value = identity.get('value', '');
        normalized = raw_value.lower().strip();
        if not normalized {
            return TransportResponse.fail(
                code='VALIDATION_ERROR',
                message='Identity value is required',
                meta=Meta(extra={'http_status': 400})
            );
        }
        # Reject if any user already owns this identity.
        if self.user_manager._identity_storage.identity_taken(normalized) {
            return TransportResponse.fail(
                code='IDENTITY_TAKEN',
                message=f"This {id_type} is already registered",
                meta=Meta(extra={'http_status': 409})
            );
        }
        emailer = self.get_emailer();
        # Email identities: hold off until we can deliver the verification mail.
        if id_type == 'email' and (emailer is None or not emailer.is_ready()) {
            return TransportResponse.fail(
                code='EMAIL_DISABLED',
                message='Email features are not configured on this server',
                meta=Meta(extra={'http_status': 503})
            );
        }
        identity_doc = {
            'type': id_type,
            'value_raw': raw_value,
            'value_normalized': normalized,
            'verified': False,
            'is_recovery': bool(body_data.is_recovery)
        };
        if not self.user_manager._identity_storage._add_identity(
            user_id, identity_doc
        ) {
            return TransportResponse.fail(
                code='NOT_FOUND',
                message='User not found',
                meta=Meta(extra={'http_status': 404})
            );
        }
        if id_type != 'email' {
            return TransportResponse.success(
                data={'status': 'added', 'verified': False},
                meta=Meta(extra={'http_status': 200})
            );
        }
        # Issue a verification token and deliver it.
        auth_cfg = get_scale_config().get_auth_config();
        ttl = auth_cfg.get('verify_token_ttl_seconds', 86400);
        url_template = auth_cfg.get('verify_url_template', '');
        token = AuthTokenStore.instance().create_token(
            user_id=user_id,
            purpose='verify',
            ttl_seconds=ttl,
            identity_value=normalized
        );
        link = url_template.replace('{token}', token) if url_template else token;
        body_text = (
            f"Hello,\n\nUse the link below to verify your email address:\n\n"
            f"{link}\n\nThis link expires in {ttl // 60} minutes.\n\n"
            "If you did not request this, you can ignore this message."
        );
        sent = emailer.send_email(
            to_addr=raw_value, subject='Verify your email address', body_text=body_text
        );
        return TransportResponse.success(
            data={
                'status': 'pending_verification',
                'verified': False,
                'email_sent': bool(sent)
            },
            meta=Meta(extra={'http_status': 202})
        );
    }
    self.server.add_endpoint(
        JEndPoint(
            method=HTTPMethod.POST,
            path='/user/add-identity',
            callback=add_identity_handler,
            request_model=AddIdentityRequest,
            response_model=None,
            tags=['User APIs'],
            summary='Attach a new identity to the authenticated user',
            description='Attaches an identity (e.g. an email) to the user. Email identities are unverified until /user/verify-identity is called.'
        )
    );
}

# ============================================================================
# /user/verify-identity  (no auth — token is the credential)
# ============================================================================
impl JacAPIServerAuth.register_verify_identity_endpoint -> None {
    async def verify_identity_handler(
        body_data: VerifyIdentityRequest
    ) -> TransportResponse {
        record = AuthTokenStore.instance().consume_token(body_data.token, 'verify');
        if record is None {
            return TransportResponse.fail(
                code='INVALID_TOKEN',
                message='Verification token is invalid or expired',
                meta=Meta(extra={'http_status': 400})
            );
        }
        user_id = record.get('user_id', '');
        identity_value = record.get('identity_value', '') or '';
        if not user_id or not identity_value {
            return TransportResponse.fail(
                code='INVALID_TOKEN',
                message='Verification token is invalid',
                meta=Meta(extra={'http_status': 400})
            );
        }
        ok = self.user_manager._identity_storage._set_identity_verified(
            user_id, identity_value
        );
        if not ok {
            return TransportResponse.fail(
                code='NOT_FOUND',
                message='Identity not found for user',
                meta=Meta(extra={'http_status': 404})
            );
        }
        return TransportResponse.success(
            data={'status': 'verified', 'identity': identity_value},
            meta=Meta(extra={'http_status': 200})
        );
    }
    self.server.add_endpoint(
        JEndPoint(
            method=HTTPMethod.POST,
            path='/user/verify-identity',
            callback=verify_identity_handler,
            request_model=VerifyIdentityRequest,
            response_model=None,
            tags=['User APIs'],
            summary='Verify an identity using a token from email',
            description='Marks the identity attached to the token as verified.'
        )
    );
}

# ============================================================================
# /user/forgot-password  (always returns 200 — never leaks account existence)
# ============================================================================
impl JacAPIServerAuth.register_forgot_password_endpoint -> None {
    async def forgot_password_handler(
        body_data: ForgotPasswordRequest
    ) -> TransportResponse {
        identity = body_data.identity.model_dump(mode='json');
        normalized = (identity.get('value', '') or '').lower().strip();
        ok_response = TransportResponse.success(
            data={
                'status': 'ok',
                'message': 'If that account exists, a reset link has been sent.'
            },
            meta=Meta(extra={'http_status': 200})
        );
        if not normalized {
            return ok_response;
        }
        emailer = self.get_emailer();
        if emailer is None or not emailer.is_ready() {
            logger.warning(
                "/user/forgot-password called but emailer is not configured"
            );
            return ok_response;
        }
        user = self.user_manager._identity_storage.find_user_by_identity(normalized);
        if user is None {
            return ok_response;
        }
        # Pick the recipient email: prefer a verified is_recovery identity, else
        # any verified email, else nothing (we still return ok_response).
        recipient_raw: (str | None) = None;
        recipient_normalized: (str | None) = None;
        for ident in user.get('identities', []) {
            if ident.get('type') != 'email' {
                continue;
            }
            if not ident.get('verified') {
                continue;
            }
            if ident.get('is_recovery') {
                recipient_raw = ident.get('value_raw');
                recipient_normalized = ident.get('value_normalized');
                break;
            }
            if recipient_raw is None {
                recipient_raw = ident.get('value_raw');
                recipient_normalized = ident.get('value_normalized');
            }
        }
        if not recipient_raw {
            return ok_response;
        }
        auth_cfg = get_scale_config().get_auth_config();
        ttl = auth_cfg.get('reset_token_ttl_seconds', 1800);
        url_template = auth_cfg.get('reset_url_template', '');
        # Invalidate prior outstanding reset tokens for this user.
        AuthTokenStore.instance().revoke_user_tokens(user.get('user_id', ''), 'reset');
        token = AuthTokenStore.instance().create_token(
            user_id=user.get('user_id', ''),
            purpose='reset',
            ttl_seconds=ttl,
            identity_value=recipient_normalized
        );
        link = url_template.replace('{token}', token) if url_template else token;
        body_text = (
            f"Hello,\n\nUse the link below to reset your password:\n\n"
            f"{link}\n\nThis link expires in {ttl // 60} minutes.\n\n"
            "If you did not request this, you can ignore this message — your "
            "password will remain unchanged."
        );
        emailer.send_email(
            to_addr=recipient_raw, subject='Reset your password', body_text=body_text
        );
        return ok_response;
    }
    self.server.add_endpoint(
        JEndPoint(
            method=HTTPMethod.POST,
            path='/user/forgot-password',
            callback=forgot_password_handler,
            request_model=ForgotPasswordRequest,
            response_model=None,
            tags=['User APIs'],
            summary='Start a password reset flow',
            description='Sends a reset link to the user\'s recovery email if the account exists. Always returns 200 to avoid leaking account existence.'
        )
    );
}

# ============================================================================
# /user/reset-password  (token-authenticated)
# ============================================================================
impl JacAPIServerAuth.register_reset_password_endpoint -> None {
    async def reset_password_handler(
        body_data: ResetPasswordRequest
    ) -> TransportResponse {
        record = AuthTokenStore.instance().consume_token(body_data.token, 'reset');
        if record is None {
            return TransportResponse.fail(
                code='INVALID_TOKEN',
                message='Reset token is invalid or expired',
                meta=Meta(extra={'http_status': 400})
            );
        }
        user_id = record.get('user_id', '');
        if not user_id {
            return TransportResponse.fail(
                code='INVALID_TOKEN',
                message='Reset token is invalid',
                meta=Meta(extra={'http_status': 400})
            );
        }
        storage = self.user_manager._identity_storage;
        # NOTE: _identity_storage is the internal handle on JacScaleUserManager;
        # we reach across the underscore boundary because the user-manager
        # public API doesn't expose a 'set password by user_id without current'
        # method (update_password() requires the current password).
        credentials = storage._get_credentials(user_id);
        new_hash = storage.hash_password(body_data.new_password);
        password_set = False;
        for cred in credentials {
            if cred.get('type') == 'password' {
                cred['password_hash'] = new_hash;
                cred.pop('algorithm', None);
                password_set = True;
            }
        }
        if not password_set {
            credentials.append({'type': 'password', 'password_hash': new_hash});
        }
        storage._update_credentials(user_id, credentials);
        # Drop any other outstanding reset tokens for this user.
        AuthTokenStore.instance().revoke_user_tokens(user_id, 'reset');
        return TransportResponse.success(
            data={'status': 'password_reset'}, meta=Meta(extra={'http_status': 200})
        );
    }
    self.server.add_endpoint(
        JEndPoint(
            method=HTTPMethod.POST,
            path='/user/reset-password',
            callback=reset_password_handler,
            request_model=ResetPasswordRequest,
            response_model=None,
            tags=['User APIs'],
            summary='Reset password using a token',
            description='Sets a new password after verifying the reset token from /user/forgot-password.'
        )
    );
}
