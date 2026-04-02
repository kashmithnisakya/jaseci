"""SQLite-backed identity storage implementation.
Stores identities and credentials as JSON columns, matching MongoDB document structure."""

impl SqliteIdentityStorage.postinit -> None {
    self._conn = sqlite3.connect(self.db_path, check_same_thread=False);
    self._conn.execute("PRAGMA journal_mode=WAL");
    self.ensure_indexes();
}

impl SqliteIdentityStorage._get_conn -> Any {
    if self._conn is None {
        self._conn = sqlite3.connect(self.db_path, check_same_thread=False);
    }
    return self._conn;
}

"""Create schema."""
impl SqliteIdentityStorage.ensure_indexes -> None {
    conn = self._get_conn();
    conn.execute("""
        CREATE TABLE IF NOT EXISTS identity_users (
            user_id TEXT PRIMARY KEY,
            status TEXT DEFAULT 'active',
            identities TEXT DEFAULT '[]',
            credentials TEXT DEFAULT '[]',
            root_id TEXT,
            role TEXT DEFAULT 'user',
            requires_password_reset INTEGER DEFAULT 0,
            created_at TEXT,
            updated_at TEXT
        )
    """);
    conn.execute("CREATE INDEX IF NOT EXISTS idx_identity_users_status ON identity_users(status)");
    conn.commit();
}

"""Create a new user with identities and credential."""
impl SqliteIdentityStorage.create_user(
    identities: list[dict[str, Any]], credential: dict[str, Any]
) -> dict[str, Any] {
    import from jaclang.jac0core.constructs { Root }
    import from jaclang { JacRuntime as Jac }

    user_id = str(uuid.uuid4());
    now = datetime.now(UTC).isoformat();
    conn = self._get_conn();

    # Normalize identities and check uniqueness
    normalized_identities: list[dict[str, Any]] = [];
    for identity in identities {
        id_type = identity.get('type', '');
        raw_value = identity.get('value', '');
        normalized = raw_value.lower().strip();

        if self.identity_taken(normalized) {
            return {'error': f"{id_type.capitalize()} is already registered"};
        }

        is_verified = identity.get('verified', (id_type == 'username'));
        normalized_identities.append({
            'type': id_type,
            'value_raw': raw_value,
            'value_normalized': normalized,
            'verified': is_verified,
            'is_recovery': (id_type == 'email')
        });
    }

    # Hash credential
    credentials: list[dict[str, Any]] = [];
    if credential.get('type') == 'password' {
        password_hash = hashlib.sha256(credential['password'].encode()).hexdigest();
        credentials.append({'type': 'password', 'password_hash': password_hash});
    }

    # Create Jac root node
    user_root = Root();
    Jac.save(user_root);
    Jac.commit(user_root);
    root_id = user_root.__jac__.id.hex;

    conn.execute(
        "INSERT INTO identity_users (user_id, status, identities, credentials, root_id, role, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (user_id, 'active', json.dumps(normalized_identities), json.dumps(credentials), root_id, 'user', now, now)
    );
    conn.commit();

    return {'user_id': user_id, 'message': 'User registered successfully'};
}

"""Find a user by user_id."""
impl SqliteIdentityStorage.get_user_by_id(user_id: str) -> dict[str, Any] | None {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT user_id, status, identities, root_id, role, requires_password_reset, created_at, updated_at FROM identity_users WHERE user_id = ?",
        (user_id, )
    );
    row = cursor.fetchone();
    if not row {
        return None;
    }
    return {
        'user_id': row[0],
        'status': row[1],
        'identities': json.loads(row[2] or '[]'),
        'root_id': row[3] or '',
        'role': row[4] or 'user',
        'requires_password_reset': bool(row[5]),
        'created_at': row[6],
        'updated_at': row[7]
    };
}

"""Check if a user exists by user_id."""
impl SqliteIdentityStorage.user_exists_by_id(user_id: str) -> bool {
    conn = self._get_conn();
    cursor = conn.execute("SELECT 1 FROM identity_users WHERE user_id = ?", (user_id, ));
    return cursor.fetchone() is not None;
}

"""Delete a user by user_id."""
impl SqliteIdentityStorage.delete_user(user_id: str) -> bool {
    conn = self._get_conn();
    cursor = conn.execute("DELETE FROM identity_users WHERE user_id = ?", (user_id, ));
    conn.commit();
    return cursor.rowcount > 0;
}

"""Find a user by any identity value (username, email, etc.)."""
impl SqliteIdentityStorage.find_user_by_identity(value: str) -> dict[str, Any] | None {
    normalized = value.lower().strip();
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT user_id, status, identities, root_id, role, requires_password_reset FROM identity_users WHERE status != 'disabled'",
    );
    for row in cursor.fetchall() {
        identities = json.loads(row[2] or '[]');
        for identity in identities {
            if identity.get('value_normalized') == normalized {
                return {
                    'user_id': row[0],
                    'status': row[1],
                    'identities': identities,
                    'root_id': row[3] or '',
                    'role': row[4] or 'user',
                    'requires_password_reset': bool(row[5])
                };
            }
        }
    }
    return None;
}

"""Check if any identity with this normalized value is already taken."""
impl SqliteIdentityStorage.identity_taken(value: str) -> bool {
    return self.find_user_by_identity(value) is not None;
}

"""Authenticate by identity value + password."""
impl SqliteIdentityStorage.authenticate(
    identifier: str, password: str
) -> dict[str, Any] | None {
    user = self.find_user_by_identity(identifier);
    if user is None {
        return None;
    }

    # Get credentials from DB
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT credentials FROM identity_users WHERE user_id = ?",
        (user['user_id'], )
    );
    row = cursor.fetchone();
    if not row {
        return None;
    }

    password_hash = hashlib.sha256(password.encode()).hexdigest();
    for cred in json.loads(row[0] or '[]') {
        if cred.get('type') == 'password' and cred.get('password_hash') == password_hash {
            return {
                'user_id': user['user_id'],
                'root_id': user['root_id'],
                'role': user.get('role', 'user')
            };
        }
    }
    return None;
}

"""Set user role."""
impl SqliteIdentityStorage.set_user_role(user_id: str, role: str) -> bool {
    conn = self._get_conn();
    cursor = conn.execute(
        "UPDATE identity_users SET role = ?, updated_at = ? WHERE user_id = ?",
        (role, datetime.now(UTC).isoformat(), user_id)
    );
    conn.commit();
    return cursor.rowcount > 0;
}

"""Get user role by user_id."""
impl SqliteIdentityStorage.get_user_role(user_id: str) -> str | None {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT role FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    if not row {
        return None;
    }
    return row[0] or 'user';
}

"""Update password (requires current password)."""
impl SqliteIdentityStorage.update_password(
    user_id: str, current_password: str, new_password: str
) -> dict[str, str] {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT credentials FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    if not row {
        return {'error': 'User not found'};
    }

    credentials = json.loads(row[0] or '[]');
    current_hash = hashlib.sha256(current_password.encode()).hexdigest();
    found = False;
    for cred in credentials {
        if cred.get('type') == 'password' and cred.get('password_hash') == current_hash {
            found = True;
            break;
        }
    }
    if not found {
        return {'error': 'Current password is incorrect'};
    }

    new_hash = hashlib.sha256(new_password.encode()).hexdigest();
    for cred in credentials {
        if cred.get('type') == 'password' {
            cred['password_hash'] = new_hash;
        }
    }
    conn.execute(
        "UPDATE identity_users SET credentials = ?, updated_at = ? WHERE user_id = ?",
        (json.dumps(credentials), datetime.now(UTC).isoformat(), user_id)
    );
    conn.commit();
    return {'user_id': user_id, 'message': 'Password updated successfully'};
}

"""List all users (excluding guest), without credentials."""
impl SqliteIdentityStorage.list_all_users(
    limit: int = 100, offset: int = 0
) -> list[dict[str, Any]] {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT user_id, status, identities, root_id, role, requires_password_reset, created_at FROM identity_users ORDER BY created_at DESC LIMIT ? OFFSET ?",
        (limit, offset)
    );
    users: list[dict[str, Any]] = [];
    for row in cursor.fetchall() {
        identities = json.loads(row[2] or '[]');
        # Skip guest user
        is_guest = False;
        for identity in identities {
            if identity.get('value_normalized') == Con.GUEST.value {
                is_guest = True;
                break;
            }
        }
        if is_guest {
            continue;
        }
        users.append({
            'user_id': row[0],
            'status': row[1],
            'identities': identities,
            'root_id': row[3] or '',
            'role': row[4] or 'user',
            'requires_password_reset': bool(row[5]),
            'created_at': row[6]
        });
    }
    return users;
}

"""Get root_id for a user."""
impl SqliteIdentityStorage.get_root_id(user_id: str) -> str | None {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT root_id FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    return row[0] if row else None;
}

"""Get the username identity for a user."""
impl SqliteIdentityStorage.get_username(user_id: str) -> str | None {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT identities FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    if row {
        for identity in json.loads(row[0] or '[]') {
            if identity.get('type') == 'username' {
                return identity.get('value_raw');
            }
        }
        # Fallback to first identity
        identities = json.loads(row[0] or '[]');
        if identities {
            return identities[0].get('value_raw');
        }
    }
    return None;
}

"""Generic field updater."""
impl SqliteIdentityStorage.update_user_fields(user_id: str, fields: dict[str, Any]) -> bool {
    conn = self._get_conn();
    set_parts: list[str] = [];
    values: list[Any] = [];
    for (key, val) in fields.items() {
        set_parts.append(f"{key} = ?");
        values.append(val);
    }
    set_parts.append("updated_at = ?");
    values.append(datetime.now(UTC).isoformat());
    values.append(user_id);
    cursor = conn.execute(
        f"UPDATE identity_users SET {', '.join(set_parts)} WHERE user_id = ?",
        tuple(values)
    );
    conn.commit();
    return cursor.rowcount > 0;
}

"""Link an SSO account by adding an identity with type=sso."""
impl SqliteIdentityStorage.link_sso_account(
    user_id: str, platform: str, external_id: str
) -> dict[str, str] {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT identities FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    if not row {
        return {'error': 'User not found'};
    }
    identities = json.loads(row[0] or '[]');

    # Check if this SSO provider+external_id is already linked
    all_cursor = conn.execute("SELECT user_id, identities FROM identity_users");
    for r in all_cursor.fetchall() {
        for identity in json.loads(r[1] or '[]') {
            if identity.get('type') == 'sso' and identity.get('provider') == platform and identity.get('external_id') == external_id {
                if r[0] == user_id {
                    return {'message': 'SSO account already linked to this user'};
                }
                return {'error': 'This SSO account is already linked to another user'};
            }
        }
    }

    now = datetime.now(UTC).isoformat();
    identities.append({
        'type': 'sso',
        'provider': platform,
        'external_id': external_id,
        'verified': True,
        'linked_at': now
    });
    conn.execute(
        "UPDATE identity_users SET identities = ?, updated_at = ? WHERE user_id = ?",
        (json.dumps(identities), now, user_id)
    );
    conn.commit();
    return {'message': 'SSO account linked successfully', 'user_id': user_id, 'platform': platform};
}

"""Unlink an SSO account."""
impl SqliteIdentityStorage.unlink_sso_account(user_id: str, platform: str) -> dict[str, str] {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT identities FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    if not row {
        return {'error': 'User not found'};
    }
    identities = json.loads(row[0] or '[]');
    original_len = len(identities);
    identities = [i for i in identities if not (i.get('type') == 'sso' and i.get('provider') == platform)];
    if len(identities) == original_len {
        return {'error': 'SSO account not found'};
    }
    conn.execute(
        "UPDATE identity_users SET identities = ?, updated_at = ? WHERE user_id = ?",
        (json.dumps(identities), datetime.now(UTC).isoformat(), user_id)
    );
    conn.commit();
    return {'message': 'SSO account unlinked successfully', 'user_id': user_id, 'platform': platform};
}

"""Get all SSO identities for a user."""
impl SqliteIdentityStorage.get_sso_accounts(user_id: str) -> list[dict[str, str]] {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT identities FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    if not row {
        return [];
    }
    accounts: list[dict[str, str]] = [];
    for identity in json.loads(row[0] or '[]') {
        if identity.get('type') == 'sso' {
            accounts.append({
                'platform': identity.get('provider', ''),
                'external_id': identity.get('external_id', ''),
                'linked_at': identity.get('linked_at', '')
            });
        }
    }
    return accounts;
}

"""Find a user by SSO provider and external_id."""
impl SqliteIdentityStorage.get_user_by_sso(
    platform: str, external_id: str
) -> dict[str, Any] | None {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT user_id, status, identities, root_id, role FROM identity_users WHERE status != 'disabled'"
    );
    for row in cursor.fetchall() {
        for identity in json.loads(row[2] or '[]') {
            if identity.get('type') == 'sso' and identity.get('provider') == platform and identity.get('external_id') == external_id {
                return {
                    'user_id': row[0],
                    'status': row[1],
                    'identities': json.loads(row[2] or '[]'),
                    'root_id': row[3] or '',
                    'role': row[4] or 'user'
                };
            }
        }
    }
    return None;
}
