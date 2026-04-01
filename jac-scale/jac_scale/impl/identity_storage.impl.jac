"""Identity-based user storage implementation."""
import hashlib;
import uuid;
import logging;
import from datetime { datetime, UTC }
import from typing { Any }
import from jaclang.jac0core.constant { Constants as Con }

glob logger = logging.getLogger(__name__);

"""Create unique indexes for identity lookups."""
impl IdentityStorage.ensure_indexes -> None {
    self.users_col.create_index(
        'identities.value_normalized', unique=True, sparse=True
    );
    self.users_col.create_index('status');
}

"""Create a new user with identities and a credential.

Returns dict with user_id + message on success, or dict with error on failure.
"""
impl IdentityStorage.create_user(
    identities: list[dict[str, Any]],
    credential: dict[str, Any]
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
            return {
                'error': f"{id_type.capitalize()} '{raw_value}' is already registered"
            };
        }

        normalized_identities.append({
            'type': id_type,
            'value_raw': raw_value,
            'value_normalized': normalized,
            'verified': (id_type == 'username'),
            'is_recovery': (id_type == 'email')
        });
    }

    # Hash credential
    credentials: list[dict[str, Any]] = [];
    if credential.get('type') == 'password' {
        password_hash = hashlib.sha256(
            credential['password'].encode()
        ).hexdigest();
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
    return self.users_col.find_one(
        {'user_id': user_id},
        {'_id': 0, 'credentials': 0}
    );
}

"""Check if a user exists by user_id."""
impl IdentityStorage.user_exists_by_id(user_id: str) -> bool {
    return self.users_col.count_documents({'user_id': user_id}, limit=1) > 0;
}

"""Delete a user by user_id."""
impl IdentityStorage.delete_user(user_id: str) -> bool {
    result = self.users_col.delete_one({'user_id': user_id});
    if result.deleted_count > 0 {
        self.sso_col.delete_many({'user_id': user_id});
        return True;
    }
    return False;
}

"""Find a user by any identity value (username, email, etc.)."""
impl IdentityStorage.find_user_by_identity(value: str) -> dict[str, Any] | None {
    normalized = value.lower().strip();
    return self.users_col.find_one(
        {
            'identities.value_normalized': normalized,
            'status': {'$ne': 'disabled'}
        },
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

    password_hash = hashlib.sha256(password.encode()).hexdigest();
    for cred in user.get('credentials', []) {
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

"""Update user status (active, pending, disabled)."""
impl IdentityStorage.update_user_status(user_id: str, status: str) -> bool {
    result = self.users_col.update_one(
        {'user_id': user_id},
        {'$set': {'status': status, 'updated_at': datetime.now(UTC).isoformat()}}
    );
    return result.matched_count > 0;
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

"""Add an identity to an existing user."""
impl IdentityStorage.add_identity(
    user_id: str, identity: dict[str, Any]
) -> dict[str, str] {
    raw_value = identity.get('value', '');
    normalized = raw_value.lower().strip();
    id_type = identity.get('type', '');

    if self.identity_taken(normalized) {
        return {'error': f"{id_type.capitalize()} '{raw_value}' is already registered"};
    }

    identity_doc = {
        'type': id_type,
        'value_raw': raw_value,
        'value_normalized': normalized,
        'verified': False,
        'is_recovery': (id_type == 'email')
    };
    result = self.users_col.update_one(
        {'user_id': user_id},
        {
            '$push': {'identities': identity_doc},
            '$set': {'updated_at': datetime.now(UTC).isoformat()}
        }
    );
    if result.matched_count == 0 {
        return {'error': 'User not found'};
    }
    return {'message': f'{id_type.capitalize()} added successfully'};
}

"""Remove an identity from a user (must keep at least one)."""
impl IdentityStorage.remove_identity(
    user_id: str, identity_type: str, value: str
) -> dict[str, str] {
    user = self.users_col.find_one({'user_id': user_id}, {'identities': 1, '_id': 0});
    if not user {
        return {'error': 'User not found'};
    }
    if len(user.get('identities', [])) <= 1 {
        return {'error': 'Cannot remove the last identity'};
    }
    normalized = value.lower().strip();
    result = self.users_col.update_one(
        {'user_id': user_id},
        {
            '$pull': {
                'identities': {
                    'type': identity_type,
                    'value_normalized': normalized
                }
            },
            '$set': {'updated_at': datetime.now(UTC).isoformat()}
        }
    );
    if result.modified_count == 0 {
        return {'error': 'Identity not found'};
    }
    return {'message': 'Identity removed successfully'};
}

"""Get all identities for a user."""
impl IdentityStorage.get_identities(user_id: str) -> list[dict[str, Any]] {
    user = self.users_col.find_one({'user_id': user_id}, {'identities': 1, '_id': 0});
    if not user {
        return [];
    }
    return user.get('identities', []);
}

"""Update password for a user (requires current password)."""
impl IdentityStorage.update_password(
    user_id: str, current_password: str, new_password: str
) -> dict[str, str] {
    user = self.users_col.find_one({'user_id': user_id}, {'credentials': 1, '_id': 0});
    if not user {
        return {'error': 'User not found'};
    }

    current_hash = hashlib.sha256(current_password.encode()).hexdigest();
    found = False;
    for cred in user.get('credentials', []) {
        if cred.get('type') == 'password' and cred.get('password_hash') == current_hash {
            found = True;
            break;
        }
    }
    if not found {
        return {'error': 'Current password is incorrect'};
    }

    new_hash = hashlib.sha256(new_password.encode()).hexdigest();
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
    ).skip(offset).limit(limit);

    users: list[dict[str, Any]] = [];
    for doc in cursor {
        users.append(doc);
    }
    return users;
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
