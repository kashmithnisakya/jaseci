"""Create unique indexes for identity lookups."""
impl IdentityStorage.ensure_indexes -> None {
    self.users_col.create_index('user_id', unique=True);
    self.users_col.create_index('identities.value_normalized', unique=True, sparse=True);
    self.users_col.create_index('status');
}

"""Create a new user with identities and a credential.

Returns dict with user_id + message on success, or dict with error on failure.
"""
impl IdentityStorage.create_user(
    identities: list[dict[str, Any]], credential: dict[str, Any]
) -> dict[str, Any] {
    import from jaclang.jac0core.constructs { Root }
    import from jaclang { JacRuntime as Jac }

    user_id = str(uuid.uuid4());
    now = datetime.now(UTC).isoformat();

    # Normalize identities and check uniqueness
    normalized_identities: list[dict[str, Any]] = [];
    for identity in identities {
        id_type = identity.get('type', '');
        raw_value = identity.get('value', '');
        normalized = raw_value.lower().strip();

        if self.identity_taken(normalized) {
            return {'error': f"{id_type.capitalize()} is already registered"};
        }

        # Use explicit verified flag if provided, otherwise username=true, rest=false
        is_verified = identity.get('verified', (id_type == 'username'));
        normalized_identities.append(
            {
                'type': id_type,
                'value_raw': raw_value,
                'value_normalized': normalized,
                'verified': is_verified,
                'is_recovery': (id_type == 'email')
            }
        );
    }

    # Hash credential
    credentials: list[dict[str, Any]] = [];
    if credential.get('type') == 'password' {
        password_hash = bcrypt.hashpw(credential['password'].encode('utf-8'), bcrypt.gensalt()).decode('utf-8');
        credentials.append({'type': 'password', 'password_hash': password_hash});
    }

    # Create Jac root node
    user_root = Root();
    Jac.save(user_root);
    Jac.commit(user_root);
    root_id = user_root.__jac__.id.hex;

    user_doc = {
        'user_id': user_id,
        'status': 'active',
        'identities': normalized_identities,
        'credentials': credentials,
        'root_id': root_id,
        'role': 'user',
        'created_at': now,
        'updated_at': now
    };
    self.users_col.insert_one(user_doc);

    return {'user_id': user_id, 'message': 'User registered successfully'};
}

"""Find a user by user_id."""
impl IdentityStorage.get_user_by_id(user_id: str) -> dict[str, Any] | None {
    return self.users_col.find_one({'user_id': user_id}, {'_id': 0, 'credentials': 0});
}

"""Check if a user exists by user_id."""
impl IdentityStorage.user_exists_by_id(user_id: str) -> bool {
    return self.users_col.count_documents({'user_id': user_id}, limit=1) > 0;
}

"""Delete a user by user_id."""
impl IdentityStorage.delete_user(user_id: str) -> bool {
    result = self.users_col.delete_one({'user_id': user_id});
    return result.deleted_count > 0;
}

"""Find a user by any identity value (username, email, etc.)."""
impl IdentityStorage.find_user_by_identity(value: str) -> dict[str, Any] | None {
    normalized = value.lower().strip();
    return self.users_col.find_one(
        {'identities.value_normalized': normalized, 'status': {'$ne': 'disabled'}},
        {'_id': 0}
    );
}

"""Check if any identity with this normalized value is already taken."""
impl IdentityStorage.identity_taken(value: str) -> bool {
    normalized = value.lower().strip();
    return self.users_col.count_documents(
        {'identities.value_normalized': normalized}, limit=1
    ) > 0;
}

"""Authenticate by looking up any identity matching identifier, then checking password."""
impl IdentityStorage.authenticate(
    identifier: str, password: str
) -> dict[str, Any] | None {
    user = self.find_user_by_identity(identifier);
    if user is None {
        return None;
    }

    for cred in user.get('credentials', []) {
        if cred.get('type') == 'password'
        and bcrypt.checkpw(password.encode('utf-8'), cred.get('password_hash', '').encode('utf-8')) {
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
impl IdentityStorage.set_user_role(user_id: str, role: str) -> bool {
    result = self.users_col.update_one(
        {'user_id': user_id},
        {'$set': {'role': role, 'updated_at': datetime.now(UTC).isoformat()}}
    );
    return result.matched_count > 0;
}

"""Get user role by user_id."""
impl IdentityStorage.get_user_role(user_id: str) -> str | None {
    user = self.users_col.find_one({'user_id': user_id}, {'role': 1, '_id': 0});
    if not user {
        return None;
    }
    return user.get('role', 'user') or 'user';
}

"""Update password for a user (requires current password)."""
impl IdentityStorage.update_password(
    user_id: str, current_password: str, new_password: str
) -> dict[str, str] {
    user = self.users_col.find_one({'user_id': user_id}, {'credentials': 1, '_id': 0});
    if not user {
        return {'error': 'User not found'};
    }

    found = False;
    for cred in user.get('credentials', []) {
        if cred.get('type') == 'password'
        and bcrypt.checkpw(current_password.encode('utf-8'), cred.get('password_hash', '').encode('utf-8')) {
            found = True;
            break;
        }
    }
    if not found {
        return {'error': 'Current password is incorrect'};
    }

    new_hash = bcrypt.hashpw(new_password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8');
    self.users_col.update_one(
        {'user_id': user_id, 'credentials.type': 'password'},
        {
            '$set': {
                'credentials.$.password_hash': new_hash,
                'updated_at': datetime.now(UTC).isoformat()
            }
        }
    );
    return {'user_id': user_id, 'message': 'Password updated successfully'};
}

"""List all users (excluding internal guest user), without credentials."""
impl IdentityStorage.list_all_users(
    limit: int = 100, offset: int = 0
) -> list[dict[str, Any]] {
    # Exclude guest user by checking for __guest__ in identities
    cursor = self.users_col.find(
        {'identities.value_normalized': {'$ne': Con.GUEST.value}},
        {'_id': 0, 'credentials': 0}
    ).sort(
        'created_at', -1
    ).skip(
        offset
    ).limit(
        limit
    );

    return list(cursor);
}

"""Get root_id for a user."""
impl IdentityStorage.get_root_id(user_id: str) -> str | None {
    user = self.users_col.find_one({'user_id': user_id}, {'root_id': 1, '_id': 0});
    return user['root_id'] if user else None;
}

"""Get the username identity for a user (first username type, or first identity value)."""
impl IdentityStorage.get_username(user_id: str) -> str | None {
    user = self.users_col.find_one({'user_id': user_id}, {'identities': 1, '_id': 0});
    if user {
        for identity in user.get('identities', []) {
            if identity.get('type') == 'username' {
                return identity.get('value_raw');
            }
        }
        # Fallback to first identity
        identities = user.get('identities', []);
        if identities {
            return identities[0].get('value_raw');
        }
    }
    return None;
}

"""Generic field updater."""
impl IdentityStorage.update_user_fields(user_id: str, fields: dict[str, Any]) -> bool {
    fields['updated_at'] = datetime.now(UTC).isoformat();
    result = self.users_col.update_one({'user_id': user_id}, {'$set': fields});
    return result.matched_count > 0;
}

"""Link an SSO account by adding an identity with type=sso and provider field."""
impl IdentityStorage.link_sso_account(
    user_id: str, platform: str, external_id: str
) -> dict[str, str] {
    # Check if this SSO external_id + provider is already linked to any user
    existing = self.users_col.find_one(
        {
            'identities': {
                '$elemMatch': {
                    'type': 'sso',
                    'provider': platform,
                    'external_id': external_id
                }
            }
        },
        {'user_id': 1, '_id': 0}
    );
    if existing {
        if existing['user_id'] == user_id {
            return {'message': 'SSO account already linked to this user'};
        }
        return {'error': 'This SSO account is already linked to another user'};
    }
    now = datetime.now(UTC).isoformat();
    identity_doc = {
        'type': 'sso',
        'provider': platform,
        'external_id': external_id,
        'verified': True,
        'linked_at': now
    };
    result = self.users_col.update_one(
        {'user_id': user_id},
        {'$push': {'identities': identity_doc}, '$set': {'updated_at': now}}
    );
    if result.matched_count == 0 {
        return {'error': 'User not found'};
    }
    return {
        'message': 'SSO account linked successfully',
        'user_id': user_id,
        'platform': platform
    };
}

"""Unlink an SSO account by removing the sso identity matching the provider."""
impl IdentityStorage.unlink_sso_account(user_id: str, platform: str) -> dict[str, str] {
    result = self.users_col.update_one(
        {'user_id': user_id},
        {
            '$pull': {'identities': {'type': 'sso', 'provider': platform}},
            '$set': {'updated_at': datetime.now(UTC).isoformat()}
        }
    );
    if result.modified_count == 0 {
        return {'error': 'SSO account not found'};
    }
    return {
        'message': 'SSO account unlinked successfully',
        'user_id': user_id,
        'platform': platform
    };
}

"""Get all SSO identities for a user."""
impl IdentityStorage.get_sso_accounts(user_id: str) -> list[dict[str, str]] {
    user = self.users_col.find_one({'user_id': user_id}, {'identities': 1, '_id': 0});
    if not user {
        return [];
    }
    accounts: list[dict[str, str]] = [];
    for identity in user.get('identities', []) {
        if identity.get('type') == 'sso' {
            accounts.append(
                {
                    'platform': identity.get('provider', ''),
                    'external_id': identity.get('external_id', ''),
                    'linked_at': identity.get('linked_at', '')
                }
            );
        }
    }
    return accounts;
}

"""Find a user by SSO provider and external_id."""
impl IdentityStorage.get_user_by_sso(
    platform: str, external_id: str
) -> dict[str, Any] | None {
    user = self.users_col.find_one(
        {
            'identities': {
                '$elemMatch': {
                    'type': 'sso',
                    'provider': platform,
                    'external_id': external_id
                }
            },
            'status': {'$ne': 'disabled'}
        },
        {'_id': 0, 'credentials': 0}
    );
    return user;
}

# ============================================================================
# SqliteIdentityStorage implementation
# ============================================================================
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

impl SqliteIdentityStorage.create_user(
    identities: list[dict[str, Any]], credential: dict[str, Any]
) -> dict[str, Any] {
    import from jaclang.jac0core.constructs { Root }
    import from jaclang { JacRuntime as Jac }

    user_id = str(uuid.uuid4());
    now = datetime.now(UTC).isoformat();
    conn = self._get_conn();

    normalized_identities: list[dict[str, Any]] = [];
    for identity in identities {
        id_type = identity.get('type', '');
        raw_value = identity.get('value', '');
        normalized = raw_value.lower().strip();
        if self.identity_taken(normalized) {
            return {'error': f"{id_type.capitalize()} is already registered"};
        }
        is_verified = identity.get('verified', (id_type == 'username'));
        normalized_identities.append(
            {
                'type': id_type,
                'value_raw': raw_value,
                'value_normalized': normalized,
                'verified': is_verified,
                'is_recovery': (id_type == 'email')
            }
        );
    }

    credentials: list[dict[str, Any]] = [];
    if credential.get('type') == 'password' {
        password_hash = bcrypt.hashpw(credential['password'].encode('utf-8'), bcrypt.gensalt()).decode('utf-8');
        credentials.append({'type': 'password', 'password_hash': password_hash});
    }

    user_root = Root();
    Jac.save(user_root);
    Jac.commit(user_root);
    root_id = user_root.__jac__.id.hex;

    conn.execute(
        "INSERT INTO identity_users (user_id, status, identities, credentials, root_id, role, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (
            user_id,
            'active',
            json.dumps(normalized_identities),
            json.dumps(credentials),
            root_id,
            'user',
            now,
            now
        )
    );
    conn.commit();
    return {'user_id': user_id, 'message': 'User registered successfully'};
}

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

impl SqliteIdentityStorage.user_exists_by_id(user_id: str) -> bool {
    conn = self._get_conn();
    cursor = conn.execute("SELECT 1 FROM identity_users WHERE user_id = ?", (user_id, ));
    return cursor.fetchone() is not None;
}

impl SqliteIdentityStorage.delete_user(user_id: str) -> bool {
    conn = self._get_conn();
    cursor = conn.execute("DELETE FROM identity_users WHERE user_id = ?", (user_id, ));
    conn.commit();
    return cursor.rowcount > 0;
}

impl SqliteIdentityStorage.find_user_by_identity(value: str) -> dict[str, Any] | None {
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

impl SqliteIdentityStorage.identity_taken(value: str) -> bool {
    return self.find_user_by_identity(value) is not None;
}

impl SqliteIdentityStorage.authenticate(
    identifier: str, password: str
) -> dict[str, Any] | None {
    user = self.find_user_by_identity(identifier);
    if user is None {
        return None;
    }
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT credentials FROM identity_users WHERE user_id = ?", (user['user_id'], )
    );
    row = cursor.fetchone();
    if not row {
        return None;
    }
    for cred in json.loads(row[0] or '[]') {
        if cred.get('type') == 'password'
        and bcrypt.checkpw(password.encode('utf-8'), cred.get('password_hash', '').encode('utf-8')) {
            return {
                'user_id': user['user_id'],
                'root_id': user['root_id'],
                'role': user.get('role', 'user')
            };
        }
    }
    return None;
}

impl SqliteIdentityStorage.set_user_role(user_id: str, role: str) -> bool {
    conn = self._get_conn();
    cursor = conn.execute(
        "UPDATE identity_users SET role = ?, updated_at = ? WHERE user_id = ?",
        (role, datetime.now(UTC).isoformat(), user_id)
    );
    conn.commit();
    return cursor.rowcount > 0;
}

impl SqliteIdentityStorage.get_user_role(user_id: str) -> str | None {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT role FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    return (row[0] or 'user') if row else None;
}

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
    found = False;
    for cred in credentials {
        if cred.get('type') == 'password'
        and bcrypt.checkpw(current_password.encode('utf-8'), cred.get('password_hash', '').encode('utf-8')) {
            found = True;
            break;
        }
    }
    if not found {
        return {'error': 'Current password is incorrect'};
    }
    new_hash = bcrypt.hashpw(new_password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8');
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

impl SqliteIdentityStorage.get_root_id(user_id: str) -> str | None {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT root_id FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    return row[0] if row else None;
}

impl SqliteIdentityStorage.get_username(user_id: str) -> str | None {
    conn = self._get_conn();
    cursor = conn.execute(
        "SELECT identities FROM identity_users WHERE user_id = ?", (user_id, )
    );
    row = cursor.fetchone();
    if row {
        identities = json.loads(row[0] or '[]');
        for identity in identities {
            if identity.get('type') == 'username' {
                return identity.get('value_raw');
            }
        }
        if identities {
            return identities[0].get('value_raw');
        }
    }
    return None;
}

impl SqliteIdentityStorage.update_user_fields(
    user_id: str, fields: dict[str, Any]
) -> bool {
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
    # Check if already linked
    all_cursor = conn.execute("SELECT user_id, identities FROM identity_users");
    for r in all_cursor.fetchall() {
        for identity in json.loads(r[1] or '[]') {
            if identity.get('type') == 'sso'
            and identity.get('provider') == platform
            and identity.get('external_id') == external_id {
                if r[0] == user_id {
                    return {'message': 'SSO account already linked to this user'};
                }
                return {'error': 'This SSO account is already linked to another user'};
            }
        }
    }
    now = datetime.now(UTC).isoformat();
    identities.append(
        {
            'type': 'sso',
            'provider': platform,
            'external_id': external_id,
            'verified': True,
            'linked_at': now
        }
    );
    conn.execute(
        "UPDATE identity_users SET identities = ?, updated_at = ? WHERE user_id = ?",
        (json.dumps(identities), now, user_id)
    );
    conn.commit();
    return {
        'message': 'SSO account linked successfully',
        'user_id': user_id,
        'platform': platform
    };
}

impl SqliteIdentityStorage.unlink_sso_account(
    user_id: str, platform: str
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
    original_len = len(identities);
    identities = [
        i
        for i in identities
        if not (i.get('type') == 'sso' and i.get('provider') == platform)
    ];
    if len(identities) == original_len {
        return {'error': 'SSO account not found'};
    }
    conn.execute(
        "UPDATE identity_users SET identities = ?, updated_at = ? WHERE user_id = ?",
        (json.dumps(identities), datetime.now(UTC).isoformat(), user_id)
    );
    conn.commit();
    return {
        'message': 'SSO account unlinked successfully',
        'user_id': user_id,
        'platform': platform
    };
}

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
            accounts.append(
                {
                    'platform': identity.get('provider', ''),
                    'external_id': identity.get('external_id', ''),
                    'linked_at': identity.get('linked_at', '')
                }
            );
        }
    }
    return accounts;
}

impl SqliteIdentityStorage.get_user_by_sso(
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
