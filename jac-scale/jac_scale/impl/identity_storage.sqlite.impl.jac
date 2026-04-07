"""SQLite storage primitives for SqliteIdentityStorage.

Each method handles SQLite-specific queries and JSON column parsing.
Business logic lives in the base IdentityStorage (identity_storage.impl.jac).
"""

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

"""Create table and indexes."""
impl SqliteIdentityStorage.ensure_indexes -> None {
    conn = self._get_conn();
    conn.execute(
        """
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
    """
    );
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_identity_users_status ON identity_users(status)"
    );
    conn.commit();
}

"""Insert a user document into SQLite."""
impl SqliteIdentityStorage._store_user(user_doc: dict[str, Any]) -> None {
    conn = self._get_conn();
    conn.execute(
        "INSERT INTO identity_users (user_id, status, identities, credentials, root_id, role, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (
            user_doc['user_id'],
            user_doc.get('status', 'active'),
            json.dumps(user_doc.get('identities', [])),
            json.dumps(user_doc.get('credentials', [])),
            user_doc.get('root_id', ''),
            user_doc.get('role', 'user'),
            user_doc.get('created_at', ''),
            user_doc.get('updated_at', '')
        )
    );
    conn.commit();
}

"""Find a user by user_id (excludes credentials)."""
impl SqliteIdentityStorage._find_by_id(user_id: str) -> dict[str, Any] | None {
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

"""Find a user by any identity value (excludes credentials)."""
impl SqliteIdentityStorage._find_by_identity(value: str) -> dict[str, Any] | None {
    normalized = value.lower().strip();
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT user_id, status, identities, root_id, role, requires_password_reset FROM identity_users WHERE status != 'disabled'"
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

"""Check if any identity with this normalized value exists."""
impl SqliteIdentityStorage._identity_exists(value: str) -> bool {
    return self._find_by_identity(value) is not None;
}

"""Delete a user by user_id."""
impl SqliteIdentityStorage._delete_by_id(user_id: str) -> bool {
    conn = self._get_conn();
    cursor = conn.execute("DELETE FROM identity_users WHERE user_id = ?", (user_id, ));
    conn.commit();
    return cursor.rowcount > 0;
}

"""Update arbitrary fields on a user row."""
impl SqliteIdentityStorage._update_fields(user_id: str, fields: dict[str, Any]) -> bool {
    conn = self._get_conn();
    set_parts: list[str] = [];
    values: list[Any] = [];
    for (key, val) in fields.items() {
        set_parts.append(f"{key} = ?");
        values.append(val);
    }
    values.append(user_id);
    cursor = conn.execute(
        f"UPDATE identity_users SET {', '.join(set_parts)} WHERE user_id = ?",
        tuple(values)
    );
    conn.commit();
    return cursor.rowcount > 0;
}

"""Get the credentials array for a user."""
impl SqliteIdentityStorage._get_credentials(user_id: str) -> list[dict[str, Any]] {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT credentials FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    if not row {
        return [];
    }
    return json.loads(row[0] or '[]');
}

"""Replace the entire credentials array for a user."""
impl SqliteIdentityStorage._update_credentials(
    user_id: str, credentials: list[dict[str, Any]]
) -> None {
    conn = self._get_conn();
    now = datetime.now(UTC).isoformat();
    conn.execute(
        "UPDATE identity_users SET credentials = ?, updated_at = ? WHERE user_id = ?",
        (json.dumps(credentials), now, user_id)
    );
    conn.commit();
}

"""Get the identities array for a user."""
impl SqliteIdentityStorage._get_identities(user_id: str) -> list[dict[str, Any]] {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT identities FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    if not row {
        return [];
    }
    return json.loads(row[0] or '[]');
}

"""Append an identity document to a user's identities array."""
impl SqliteIdentityStorage._add_identity(user_id: str, identity: dict[str, Any]) -> bool {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT identities FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    if not row {
        return False;
    }
    identities = json.loads(row[0] or '[]');
    identities.append(identity);
    now = datetime.now(UTC).isoformat();
    conn.execute(
        "UPDATE identity_users SET identities = ?, updated_at = ? WHERE user_id = ?",
        (json.dumps(identities), now, user_id)
    );
    conn.commit();
    return True;
}

"""Remove an SSO identity matching the provider from a user."""
impl SqliteIdentityStorage._remove_sso_identity(user_id: str, platform: str) -> bool {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT identities FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    if not row {
        return False;
    }
    identities = json.loads(row[0] or '[]');
    original_len = len(identities);
    identities = [
        i
        for i in identities
        if not (i.get('type') == 'sso' and i.get('provider') == platform)
    ];
    if len(identities) == original_len {
        return False;
    }
    now = datetime.now(UTC).isoformat();
    conn.execute(
        "UPDATE identity_users SET identities = ?, updated_at = ? WHERE user_id = ?",
        (json.dumps(identities), now, user_id)
    );
    conn.commit();
    return True;
}

"""Find which user (if any) has a specific SSO link. Returns {user_id} or None."""
impl SqliteIdentityStorage._find_sso_link(
    platform: str, external_id: str
) -> dict[str, Any] | None {
    conn = self._get_conn();
    cursor = conn.execute("SELECT user_id, identities FROM identity_users");
    for row in cursor.fetchall() {
        for identity in json.loads(row[1] or '[]') {
            if identity.get('type') == 'sso'
            and identity.get('provider') == platform
            and identity.get('external_id') == external_id {
                return {'user_id': row[0]};
            }
        }
    }
    return None;
}

"""Find a user by SSO provider and external_id (excludes credentials, skips disabled)."""
impl SqliteIdentityStorage._find_user_by_sso(
    platform: str, external_id: str
) -> dict[str, Any] | None {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT user_id, status, identities, root_id, role FROM identity_users WHERE status != 'disabled'"
    );
    for row in cursor.fetchall() {
        for identity in json.loads(row[2] or '[]') {
            if identity.get('type') == 'sso'
            and identity.get('provider') == platform
            and identity.get('external_id') == external_id {
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

"""List user documents excluding guest users and credentials."""
impl SqliteIdentityStorage._list_user_docs(
    limit: int, offset: int
) -> list[dict[str, Any]] {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT user_id, status, identities, root_id, role, requires_password_reset, created_at FROM identity_users ORDER BY created_at DESC LIMIT ? OFFSET ?",
        (limit, offset)
    );
    users: list[dict[str, Any]] = [];
    for row in cursor.fetchall() {
        identities = json.loads(row[2] or '[]');
        is_guest = any(i.get('value_normalized') == Con.GUEST.value for i in identities);
        if is_guest {
            continue;
        }
        users.append(
            {
                'user_id': row[0],
                'status': row[1],
                'identities': identities,
                'root_id': row[3] or '',
                'role': row[4] or 'user',
                'requires_password_reset': bool(row[5]),
                'created_at': row[6]
            }
        );
    }
    return users;
}
