"""SQLite storage primitives for SqliteIdentityStorage using SQLAlchemy Core.

Business logic lives in the base IdentityStorage (identity_storage.impl.jac).
"""

impl SqliteIdentityStorage.postinit -> None {
    self._engine = create_engine(f"sqlite:///{self.db_path}", echo=False);
    metadata = MetaData();
    self._table = Table(
        'identity_users',
        metadata,
        Column('user_id', String, primary_key=True),
        Column('status', String, default='active'),
        Column('identities', JSON, default=[]),
        Column('credentials', JSON, default=[]),
        Column('root_id', String),
        Column('role', String, default='user'),
        Column('requires_password_reset', Integer, default=0),
        Column('created_at', String),
        Column('updated_at', String)
    );
    self.ensure_indexes();
}

"""Create table and indexes."""
impl SqliteIdentityStorage.ensure_indexes -> None {
    self._table.metadata.create_all(self._engine);
}

"""Helper to convert a row to a dict (excludes credentials)."""
def _row_to_dict(row: Any) -> dict[str, Any] {
    return {
        'user_id': row.user_id,
        'status': row.status,
        'identities': row.identities or [],
        'root_id': row.root_id or '',
        'role': row.role or 'user',
        'requires_password_reset': bool(row.requires_password_reset),
        'created_at': row.created_at,
        'updated_at': row.updated_at
    };
}

"""Insert a user document."""
impl SqliteIdentityStorage._store_user(user_doc: dict[str, Any]) -> None {
    with self._engine.begin() as conn {
        conn.execute(self._table.insert().values(**user_doc));
    }
}

"""Find a user by user_id (excludes credentials)."""
impl SqliteIdentityStorage.get_user_by_id(user_id: str) -> dict[str, Any] | None {
    t = self._table;
    with self._engine.connect() as conn {
        row = conn.execute(select(t).where(t.c.user_id == user_id)).first();
        if not row {
            return None;
        }
        return _row_to_dict(row);
    }
}

"""Find a user by any identity value (excludes credentials)."""
impl SqliteIdentityStorage.find_user_by_identity(value: str) -> dict[str, Any] | None {
    normalized = value.lower().strip();
    t = self._table;
    with self._engine.connect() as conn {
        rows = conn.execute(select(t).where(t.c.status != 'disabled')).fetchall();
        for row in rows {
            for identity in (row.identities or []) {
                if identity.get('value_normalized') == normalized {
                    return _row_to_dict(row);
                }
            }
        }
    }
    return None;
}

"""Check if any identity with this normalized value exists."""
impl SqliteIdentityStorage.identity_taken(value: str) -> bool {
    return self.find_user_by_identity(value) is not None;
}

"""Delete a user by user_id."""
impl SqliteIdentityStorage.delete_user(user_id: str) -> bool {
    t = self._table;
    with self._engine.begin() as conn {
        result = conn.execute(delete(t).where(t.c.user_id == user_id));
        return result.rowcount > 0;
    }
}

"""Update fields on a user row."""
impl SqliteIdentityStorage._update_fields(
    user_id: str, fields: dict[str, Any]
) -> bool {
    allowed = {c.name for c in self._table.columns} - {'user_id','created_at'};
    safe_fields = {
        k: v
        for (k, v) in fields.items()
        if k in allowed
    };
    if not safe_fields {
        return False;
    }
    t = self._table;
    with self._engine.begin() as conn {
        result = conn.execute(
            update(t).where(t.c.user_id == user_id).values(**safe_fields)
        );
        return result.rowcount > 0;
    }
}

"""Get the credentials array for a user."""
impl SqliteIdentityStorage._get_credentials(user_id: str) -> list[dict[str, Any]] {
    t = self._table;
    with self._engine.connect() as conn {
        row = conn.execute(select(t.c.credentials).where(t.c.user_id == user_id)).first();
        return (row[0] or []) if row else [];
    }
}

"""Replace the entire credentials array for a user."""
impl SqliteIdentityStorage._update_credentials(
    user_id: str, credentials: list[dict[str, Any]]
) -> None {
    t = self._table;
    now = datetime.now(UTC).isoformat();
    with self._engine.begin() as conn {
        conn.execute(
            update(t).where(t.c.user_id == user_id).values(
                credentials=credentials, updated_at=now
            )
        );
    }
}

"""Get the identities array for a user."""
impl SqliteIdentityStorage._get_identities(user_id: str) -> list[dict[str, Any]] {
    t = self._table;
    with self._engine.connect() as conn {
        row = conn.execute(select(t.c.identities).where(t.c.user_id == user_id)).first();
        return (row[0] or []) if row else [];
    }
}

"""Append an identity document to a user's identities array."""
impl SqliteIdentityStorage._add_identity(
    user_id: str, identity: dict[str, Any]
) -> bool {
    t = self._table;
    with self._engine.begin() as conn {
        row = conn.execute(select(t.c.identities).where(t.c.user_id == user_id)).first();
        if not row {
            return False;
        }
        identities = list(row[0] or []);
        identities.append(identity);
        now = datetime.now(UTC).isoformat();
        conn.execute(
            update(t).where(t.c.user_id == user_id).values(
                identities=identities, updated_at=now
            )
        );
        return True;
    }
}

"""Remove an SSO identity matching the provider from a user."""
impl SqliteIdentityStorage._remove_sso_identity(user_id: str, platform: str) -> bool {
    t = self._table;
    with self._engine.begin() as conn {
        row = conn.execute(select(t.c.identities).where(t.c.user_id == user_id)).first();
        if not row {
            return False;
        }
        identities = list(row[0] or []);
        filtered = [
            i
            for i in identities
            if not (i.get('type') == 'sso' and i.get('provider') == platform)
        ];
        if len(filtered) == len(identities) {
            return False;
        }
        now = datetime.now(UTC).isoformat();
        conn.execute(
            update(t).where(t.c.user_id == user_id).values(
                identities=filtered, updated_at=now
            )
        );
        return True;
    }
}

"""Find which user (if any) has a specific SSO link."""
impl SqliteIdentityStorage._find_sso_link(
    platform: str, external_id: str
) -> dict[str, Any] | None {
    t = self._table;
    with self._engine.connect() as conn {
        rows = conn.execute(select(t.c.user_id, t.c.identities)).fetchall();
        for row in rows {
            for identity in (row.identities or []) {
                if identity.get('type') == 'sso'
                and identity.get('provider') == platform
                and identity.get('external_id') == external_id {
                    return {'user_id': row.user_id};
                }
            }
        }
    }
    return None;
}

"""Find a user by SSO provider and external_id (excludes credentials, skips disabled)."""
impl SqliteIdentityStorage.get_user_by_sso(
    platform: str, external_id: str
) -> dict[str, Any] | None {
    t = self._table;
    with self._engine.connect() as conn {
        rows = conn.execute(select(t).where(t.c.status != 'disabled')).fetchall();
        for row in rows {
            for identity in (row.identities or []) {
                if identity.get('type') == 'sso'
                and identity.get('provider') == platform
                and identity.get('external_id') == external_id {
                    return _row_to_dict(row);
                }
            }
        }
    }
    return None;
}

"""List user documents excluding guest users and credentials."""
impl SqliteIdentityStorage.list_all_users(
    limit: int, offset: int
) -> list[dict[str, Any]] {
    t = self._table;
    with self._engine.connect() as conn {
        rows = conn.execute(
            select(t).order_by(t.c.created_at.desc()).limit(limit).offset(offset)
        ).fetchall();
        users: list[dict[str, Any]] = [];
        for row in rows {
            identities = row.identities or [];
            is_guest = any(
                i.get('value_normalized') == Con.GUEST.value for i in identities
            );
            if is_guest {
                continue;
            }
            users.append(_row_to_dict(row));
        }
        return users;
    }
}
