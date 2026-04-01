impl JacScaleUserManager.postinit -> None {
    sso_config = get_scale_config().get_sso_config();
    for platform in Platforms {
        key = platform.value.lower();
        platform_config = sso_config.get(key, {});
        client_id = platform_config.get('client_id', '');
        client_secret = platform_config.get('client_secret', '');
        if not client_id or not client_secret {
            continue;
        }
        self.SUPPORTED_PLATFORMS[platform.value] = {
            "client_id": client_id,
            "client_secret": client_secret
        };
    }

    db_config = get_scale_config().get_database_config();
    mongodb_uri = db_config.get('mongodb_uri');

    if mongodb_uri is not None {
        import from jac_scale.db { get_mongo_client }
        client = get_mongo_client();
        db = client['jac_db'];
        sso_col = db['sso_accounts'];
        sso_col.create_index([('platform', 1), ('external_id', 1)], unique=True);
        sso_col.create_index('user_id');
        self._identity_storage = IdentityStorage(
            users_col=db['users'], sso_col=sso_col
        );
        self._identity_storage.ensure_indexes();
    } else {
        self._identity_storage = None;
        super.postinit();
        self._init_sqlite_schema();
    }
}

"""Initialize SQLite schema for extended fields."""
impl JacScaleUserManager._init_sqlite_schema -> None {
    self._ensure_connection();
    self._conn.execute(
        """
        CREATE TABLE IF NOT EXISTS sso_accounts (
            user_id TEXT NOT NULL,
            platform TEXT NOT NULL,
            external_id TEXT NOT NULL,
            email TEXT,
            linked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (platform, external_id),
            FOREIGN KEY (user_id) REFERENCES users(username) ON DELETE CASCADE
        )
    """
    );
    self._conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_sso_accounts_user_id ON sso_accounts(user_id)"
    );
    cursor = self._conn.execute("PRAGMA table_info(users)");
    cols = {row[1] for row in cursor.fetchall()};
    if 'role' not in cols {
        self._conn.execute("ALTER TABLE users ADD COLUMN role TEXT DEFAULT 'user'");
    }
    if 'requires_password_reset' not in cols {
        self._conn.execute(
            "ALTER TABLE users ADD COLUMN requires_password_reset INTEGER DEFAULT 0"
        );
    }
    if 'is_password_required' not in cols {
        self._conn.execute(
            "ALTER TABLE users ADD COLUMN is_password_required INTEGER DEFAULT 1"
        );
    }
    if 'user_id' not in cols {
        self._conn.execute("ALTER TABLE users ADD COLUMN user_id TEXT");
    }
    self._conn.commit();
}

impl JacScaleUserManager._ensure_connection -> None {
    if self._identity_storage is None {
        super._ensure_connection();
    }
}

# ============================================================================
# Identity-based User CRUD
# ============================================================================

"""Create a user with identity-based model. Falls back to flat model for SQLite."""
impl JacScaleUserManager.create_user(
    identities: list[dict[str, Any]], credential: dict[str, Any]
) -> dict[str, Any] {
    if self._identity_storage {
        return self._identity_storage.create_user(identities, credential);
    }
    # SQLite fallback: extract username from identities, password from credential
    username = '';
    for identity in identities {
        if identity.get('type') == 'username' {
            username = identity.get('value', '');
            break;
        }
    }
    if not username {
        username = identities[0].get('value', '') if identities else '';
    }
    password = credential.get('password', '');
    result = super.create_user(username, password);
    if 'error' not in result {
        result['user_id'] = result.get('username', username);
        result['message'] = 'User registered successfully';
    }
    return result;
}

"""Convenience method for creating internal users (guest, system, admin)."""
impl JacScaleUserManager.create_internal_user(
    username: str, password: str
) -> dict[str, Any] {
    return self.create_user(
        identities=[{'type': 'username', 'value': username}],
        credential={'type': 'password', 'password': password}
    );
}

"""Authenticate by any identity value (username or email) + password."""
impl JacScaleUserManager.authenticate(
    identifier: str, password: str
) -> dict[str, Any] | None {
    if self._identity_storage {
        return self._identity_storage.authenticate(identifier, password);
    }
    # SQLite fallback
    result = super.authenticate(identifier, password);
    if result {
        result['user_id'] = result.get('username', identifier);
    }
    return result;
}

"""Find a user by any identity value."""
impl JacScaleUserManager.find_user_by_identity(
    value: str
) -> dict[str, Any] | None {
    if self._identity_storage {
        return self._identity_storage.find_user_by_identity(value);
    }
    return self.get_user(value);
}

"""Check if a user exists by user_id."""
impl JacScaleUserManager.user_exists(user_id: str) -> bool {
    if self._identity_storage {
        return self._identity_storage.user_exists_by_id(user_id);
    }
    return super.user_exists(user_id);
}

"""Get user by user_id."""
impl JacScaleUserManager.get_user(user_id: str) -> dict[str, Any] | None {
    if self._identity_storage {
        return self._identity_storage.get_user_by_id(user_id);
    }
    return super.get_user(user_id);
}

"""Get root_id by user_id."""
impl JacScaleUserManager.get_root_id(user_id: str) -> str | None {
    if self._identity_storage {
        return self._identity_storage.get_root_id(user_id);
    }
    return super.get_root_id(user_id);
}

"""Update password by user_id."""
impl JacScaleUserManager.update_password(
    user_id: str, current_password: str, new_password: str
) -> dict[str, str] {
    if self._identity_storage {
        return self._identity_storage.update_password(
            user_id, current_password, new_password
        );
    }
    return super.update_password(user_id, current_password, new_password);
}

impl JacScaleUserManager.validate_token(token: str) -> str | None {
    return self.validate_jwt_token(token);
}

impl JacScaleUserManager.close -> None { }

"""Get username from user_id."""
impl JacScaleUserManager.get_username(user_id: str) -> str | None {
    if self._identity_storage {
        return self._identity_storage.get_username(user_id);
    }
    return user_id;
}

# ============================================================================
# JWT Methods — now use user_id as the primary claim
# ============================================================================

impl JacScaleUserManager.create_jwt_token(
    user_id: str, include_role: bool = True
) -> str {
    now = datetime.now(UTC);
    payload: dict[(str, Any)] = {
        'user_id': user_id,
        'exp': (now + timedelta(days=JWT_EXP_DELTA_DAYS)),
        'iat': now.timestamp()
    };
    if include_role {
        role = self.get_user_role(user_id);
        if role {
            payload['role'] = role;
        }
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM);
}

impl JacScaleUserManager.get_jwt_claims(token: str) -> dict | None {
    try {
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM]);
    } except Exception as e {
        logger.debug(f"Failed to decode JWT token: {str(e)}");
        return None;
    }
}

"""Validate JWT and return user_id if valid."""
impl JacScaleUserManager.validate_jwt_token(token: str) -> str | None {
    try {
        decoded = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM]);
        user_id = decoded.get('user_id');
        if not user_id {
            return None;
        }
        return user_id if self.user_exists(user_id) else None;
    } except Exception as e {
        logger.debug(f"Failed to validate JWT token: {str(e)}");
        return None;
    }
}

impl JacScaleUserManager.refresh_jwt_token(token: str) -> str | None {
    try {
        decoded = jwt.decode(
            token, JWT_SECRET, algorithms=[JWT_ALGORITHM], options={"verify_exp": True}
        );
        user_id = decoded.get('user_id');
        return self.create_jwt_token(user_id) if user_id else None;
    } except Exception as e {
        logger.debug(f"Failed to refresh JWT token: {str(e)}");
        return None;
    }
}

# ============================================================================
# SSO Methods
# ============================================================================

impl JacScaleUserManager.get_sso(platform: str) -> SSOProvider | None {
    if platform not in self.SUPPORTED_PLATFORMS {
        return None;
    }
    credentials = self.SUPPORTED_PLATFORMS[platform];
    redirect_uri = f"{SSO_HOST}/sso/{platform}/callback";
    if platform == Platforms.GOOGLE.value {
        import from jac_scale.sso.google { GoogleSSOProvider }
        return GoogleSSOProvider(
            client_id=credentials['client_id'],
            client_secret=credentials['client_secret'],
            redirect_uri=redirect_uri,
            allow_insecure_http=True
        );
    }
    if platform == Platforms.APPLE.value {
        import from jac_scale.sso.apple { AppleSSOProvider }
        return AppleSSOProvider(
            client_id=credentials['client_id'],
            client_secret=credentials['client_secret'],
            redirect_uri=redirect_uri,
            allow_insecure_http=True
        );
    }
    if platform == Platforms.GITHUB.value {
        import from jac_scale.sso.github { GithubSSOProvider }
        return GithubSSOProvider(
            client_id=credentials['client_id'],
            client_secret=credentials['client_secret'],
            redirect_uri=redirect_uri,
            allow_insecure_http=True
        );
    }
    return None;
}

impl JacScaleUserManager.sso_initiate(
    platform: str, operation: str
) -> Response | TransportResponse {
    if platform not in [p.value for p in Platforms] {
        return TransportResponse.fail(
            code='INVALID_PLATFORM',
            message=f"Invalid platform '{platform}'. Supported platforms: {', '.join(
                [p.value for p in Platforms]
            )}",
            meta=Meta(extra={'http_status': 400})
        );
    }
    if platform not in self.SUPPORTED_PLATFORMS {
        return TransportResponse.fail(
            code='SSO_NOT_CONFIGURED',
            message=f"SSO for platform '{platform}' is not configured. Please set SSO_{platform.upper()}_CLIENT_ID and SSO_{platform.upper()}_CLIENT_SECRET environment variables.",
            meta=Meta(extra={'http_status': 501})
        );
    }
    if operation not in [o.value for o in Operations] {
        return TransportResponse.fail(
            code='INVALID_OPERATION',
            message=f"Invalid operation '{operation}'. Must be 'login' or 'register'",
            meta=Meta(extra={'http_status': 400})
        );
    }
    sso = self.get_sso(platform);
    if not sso {
        return TransportResponse.fail(
            code='SSO_INIT_FAILED',
            message=f"Failed to initialize SSO for platform '{platform}'",
            meta=Meta(extra={'http_status': 500})
        );
    }
    return await sso.initiate_auth();
}

impl JacScaleUserManager.sso_callback(
    request: Request, platform: str
) -> TransportResponse {
    import from jaclang.runtimelib.server { JsonValue }
    if platform not in [p.value for p in Platforms] {
        return TransportResponse.fail(
            code='INVALID_PLATFORM',
            message=f"Invalid platform '{platform}'. Supported platforms: {', '.join(
                [p.value for p in Platforms]
            )}",
            meta=Meta(extra={'http_status': 400})
        );
    }
    if platform not in self.SUPPORTED_PLATFORMS {
        return TransportResponse.fail(
            code='SSO_NOT_CONFIGURED',
            message=f"SSO for platform '{platform}' is not configured.",
            meta=Meta(extra={'http_status': 501})
        );
    }
    sso = self.get_sso(platform);
    if not sso {
        return TransportResponse.fail(
            code='SSO_INIT_FAILED',
            message=f"Failed to initialize SSO for platform '{platform}'",
            meta=Meta(extra={'http_status': 500})
        );
    }
    try {
        user_info = await sso.handle_callback(request);
        email = user_info.email;
        if not email {
            return TransportResponse.fail(
                code='EMAIL_MISSING',
                message=f"Email not provided by {platform}",
                meta=Meta(extra={'http_status': 400})
            );
        }
        existing = self.find_user_by_identity(email);
        if existing {
            user_id = existing.get('user_id', '');
            token = self.create_jwt_token(user_id);
            return TransportResponse.success(
                data={
                    'message': 'Login successful',
                    'user_id': user_id,
                    'token': token,
                    'platform': platform,
                    'root_id': existing.get('root_id', '')
                },
                meta=Meta(extra={'http_status': 200})
            );
        } else {
            result = self.create_user(
                identities=[{'type': 'email', 'value': email}],
                credential={'type': 'password', 'password': generate_random_password()}
            );
            if 'error' in result {
                return TransportResponse.fail(
                    code='USER_CREATION_FAILED',
                    message=result.get('error', 'User creation failed'),
                    meta=Meta(extra={'http_status': 400})
                );
            }
            user_id = result.get('user_id', '');
            result['token'] = self.create_jwt_token(user_id);
            result['platform'] = platform;
            return TransportResponse.success(
                data=result, meta=Meta(extra={'http_status': 201})
            );
        }
    } except Exception as e {
        return TransportResponse.fail(
            code='AUTHENTICATION_FAILED',
            message=f"Authentication failed: {str(e)}",
            meta=Meta(extra={'http_status': 500})
        );
    }
}

# ============================================================================
# SSO Account Linking
# ============================================================================

impl JacScaleUserManager.link_sso_account(
    user_id: str, platform: str, external_id: str, email: str
) -> dict[str, str] {
    self._ensure_connection();
    cursor = self._conn.execute(
        "SELECT user_id FROM sso_accounts WHERE platform = ? AND external_id = ?",
        (platform, external_id)
    );
    existing = cursor.fetchone();
    if existing {
        if existing[0] == user_id {
            return {'message': 'SSO account already linked to this user'};
        }
        return {'error': 'This SSO account is already linked to another user'};
    }
    self._conn.execute(
        "INSERT INTO sso_accounts (user_id, platform, external_id, email) VALUES (?, ?, ?, ?)",
        (user_id, platform, external_id, email)
    );
    self._conn.commit();
    return {
        'message': 'SSO account linked successfully',
        'user_id': user_id,
        'platform': platform
    };
}

impl JacScaleUserManager.unlink_sso_account(
    user_id: str, platform: str
) -> dict[str, str] {
    self._ensure_connection();
    cursor = self._conn.execute(
        "DELETE FROM sso_accounts WHERE user_id = ? AND platform = ?",
        (user_id, platform)
    );
    self._conn.commit();
    if cursor.rowcount == 0 {
        return {'error': 'SSO account not found'};
    }
    return {
        'message': 'SSO account unlinked successfully',
        'user_id': user_id,
        'platform': platform
    };
}

impl JacScaleUserManager.get_sso_accounts(user_id: str) -> list[dict[str, str]] {
    self._ensure_connection();
    cursor = self._conn.execute(
        "SELECT platform, external_id, email, linked_at FROM sso_accounts WHERE user_id = ? ORDER BY linked_at DESC",
        (user_id, )
    );
    return [
        {'platform': r[0], 'external_id': r[1], 'email': r[2], 'linked_at': r[3]}
        for r in cursor.fetchall()
    ];
}

impl JacScaleUserManager.get_user_by_sso(
    platform: str, external_id: str
) -> dict[str, str] | None {
    self._ensure_connection();
    cursor = self._conn.execute(
        "SELECT sa.user_id, u.token, u.root_id FROM sso_accounts sa JOIN users u ON sa.user_id = u.username WHERE sa.platform = ? AND sa.external_id = ?",
        (platform, external_id)
    );
    row = cursor.fetchone();
    return {'email': row[0], 'token': row[1], 'root_id': row[2]} if row else None;
}

# ============================================================================
# User Role and Admin Management
# ============================================================================

impl JacScaleUserManager.get_user_role(user_id: str) -> str | None {
    if self._identity_storage {
        return self._identity_storage.get_user_role(user_id);
    }
    self._ensure_connection();
    cursor = self._conn.execute(
        "SELECT role FROM users WHERE username = ?", (user_id, )
    );
    row = cursor.fetchone();
    return (row[0] or 'user') if row else None;
}

impl JacScaleUserManager.set_user_role(user_id: str, role: str) -> dict[str, str] {
    valid_roles = [r.value for r in UserRole];
    if role not in valid_roles {
        return {'error': f"Invalid role. Must be one of: {', '.join(valid_roles)}"};
    }
    if self._identity_storage {
        success = self._identity_storage.set_user_role(user_id, role);
        if not success {
            return {'error': 'User not found'};
        }
        return {'message': f"Role updated to '{role}'", 'user_id': user_id, 'role': role};
    }
    self._ensure_connection();
    cursor = self._conn.execute(
        "UPDATE users SET role = ? WHERE username = ?", (role, user_id)
    );
    self._conn.commit();
    if cursor.rowcount == 0 {
        return {'error': 'User not found'};
    }
    return {'message': f"Role updated to '{role}'", 'user_id': user_id, 'role': role};
}

impl JacScaleUserManager.is_admin(user_id: str) -> bool {
    return self.get_user_role(user_id) == 'admin';
}

impl JacScaleUserManager.list_all_users(
    limit: int = 100, offset: int = 0
) -> list[dict[str, Any]] {
    if self._identity_storage {
        return self._identity_storage.list_all_users(limit, offset);
    }
    self._ensure_connection();
    cursor = self._conn.execute(
        "SELECT username, root_id, role, requires_password_reset, is_password_required, user_id FROM users WHERE username != ? ORDER BY username LIMIT ? OFFSET ?",
        (Con.GUEST.value, limit, offset)
    );
    return [
        {
            'username': r[0] or '',
            'root_id': r[1] or '',
            'role': r[2] or 'user',
            'requires_password_reset': bool(r[3]),
            'is_password_required': bool(r[4]) if r[4] is not None else True,
            'user_id': r[5]
        } for r in cursor.fetchall()
    ];
}

impl JacScaleUserManager.delete_user(user_id: str) -> dict[str, str] {
    if self._identity_storage {
        success = self._identity_storage.delete_user(user_id);
        if not success {
            return {'error': 'User not found'};
        }
        return {'message': 'User deleted successfully', 'user_id': user_id};
    }
    self._ensure_connection();
    cursor = self._conn.execute("DELETE FROM users WHERE username = ?", (user_id, ));
    self._conn.commit();
    if cursor.rowcount == 0 {
        return {'error': 'User not found'};
    }
    self._conn.execute("DELETE FROM sso_accounts WHERE user_id = ?", (user_id, ));
    self._conn.commit();
    return {'message': 'User deleted successfully', 'user_id': user_id};
}

impl JacScaleUserManager.bootstrap_admin_user -> dict[str, str] {
    admin_config = get_scale_config().get_admin_config();
    if not admin_config.get('enabled', True) {
        return {'message': 'Admin portal is disabled'};
    }
    admin_username = admin_config.get('username', 'admin');
    default_password = admin_config.get('default_password', 'changeme');

    existing = self.find_user_by_identity(admin_username);
    if existing {
        user_id = existing.get('user_id', '');
        if self.get_user_role(user_id) != 'admin' {
            self.set_user_role(user_id, 'admin');
            logger.info(f"Existing user '{admin_username}' promoted to admin role");
        }
        return {'message': 'Admin user already exists', 'username': admin_username};
    }

    result = self.create_internal_user(admin_username, default_password);
    if 'error' in result {
        return result;
    }
    user_id = result.get('user_id', '');
    self.set_user_role(user_id, 'admin');

    logger.warning(
        f"Admin user '{admin_username}' created with default password. Please change immediately!"
    );
    return {
        'message': 'Admin user created successfully',
        'username': admin_username,
        'user_id': user_id
    };
}

impl JacScaleUserManager.create_user_as_admin(
    username: str,
    password: str,
    role: str = 'user',
    requires_password_reset: bool = True
) -> dict[str, Any] {
    valid_roles = [r.value for r in UserRole];
    if role not in valid_roles {
        return {'error': f"Invalid role. Must be one of: {', '.join(valid_roles)}"};
    }
    result = self.create_internal_user(username, password);
    if 'error' in result {
        return result;
    }
    user_id = result.get('user_id', '');

    if self._identity_storage {
        self._identity_storage.update_user_fields(user_id, {'role': role});
    } else {
        self._ensure_connection();
        self._conn.execute(
            "UPDATE users SET role = ?, requires_password_reset = ? WHERE username = ?",
            (role, 1 if requires_password_reset else 0, username)
        );
        self._conn.commit();
    }
    result['role'] = role;
    result['requires_password_reset'] = str(requires_password_reset);
    return result;
}
