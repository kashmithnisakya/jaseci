"""Grafana credential manager implementation.

Uses the Grafana HTTP API to manage users and sync credentials.
Follows the same singleton + DB persistence pattern as JacScaleScheduler.
"""
import json;
import base64;
import datetime;
import from typing { Any }
import from urllib.request { Request as HttpRequest, urlopen }
import from urllib.error { URLError, HTTPError }
import from jac_scale.config_loader { get_scale_config }
import from jac_scale.db { Db, get_mongo_client }
import from jac_scale.utils { generate_random_password }

"""Initialise instance with its own in-memory store."""
impl GrafanaManager.postinit -> None {
    self._in_memory_store = {};
}

"""Return or create the module-level singleton GrafanaManager."""
impl GrafanaManager.instance -> GrafanaManager {
    global _grafana_manager;
    if _grafana_manager is not None {
        return _grafana_manager;
    }
    _grafana_manager = GrafanaManager();
    return _grafana_manager;
}

"""Set up the manager with credentials from monitoring config and DB connection."""
impl GrafanaManager.setup(
    admin_password: str,
    monitoring_user: str = 'jac-monitor',
    monitoring_password: str = '',
    grafana_url: (str | None) = None
) -> None {
    self._grafana_url = grafana_url;
    self._admin_password = admin_password;
    self._monitoring_user = monitoring_user;
    self._monitoring_password = monitoring_password;
    self._collection = 'grafana_credentials';

    # Initialise DB connection (MongoDB with in-memory fallback)
    db_cfg = get_scale_config().get_database_config();
    if db_cfg.get('mongodb_uri') {
        try {
            self._db = Db(client=get_mongo_client(), db_name='jac_scale');
            logger.debug("GrafanaManager: MongoDB configured for credential storage");
        } except Exception as e {
            logger.warning(
                f"GrafanaManager: MongoDB connection failed, using in-memory: {e}"
            );
            self._db = None;
        }
    }
    self._initialized = True;

    logger.info(
        f"GrafanaManager initialised (url={self._grafana_url}, "
        f"monitoring_user={self._monitoring_user})"
    );
}

"""Full credential sync: verify admin auth, ensure monitoring user exists."""
impl GrafanaManager.sync_credentials -> dict[str, Any] {
    result: dict[str, Any] = {
        'grafana_reachable': False,
        'admin_auth_ok': False,
        'monitoring_user_synced': False
    };

    if not self._grafana_url {
        logger.warning("GrafanaManager: No Grafana URL configured, skipping sync");
        return result;
    }

    # Check Grafana health
    if not self._check_health() {
        logger.warning(
            f"GrafanaManager: Grafana not reachable at {self._grafana_url}, "
            "skipping sync"
        );
        return result;
    }
    result['grafana_reachable'] = True;

    # Verify admin auth
    if not self._verify_admin_auth() {
        logger.warning(
            "GrafanaManager: Admin auth failed — Grafana admin password may "
            "differ from config. Use POST /admin/grafana/sync to recover."
        );
        return result;
    }
    result['admin_auth_ok'] = True;

    # If admin changed password while monitoring was disabled, sync it now
    persisted_pw = self._decrypt_persisted_admin_password();
    if persisted_pw and persisted_pw != self._admin_password {
        logger.info("GrafanaManager: Syncing pending admin password change");
        if self.sync_admin_password(persisted_pw) {
            result['admin_password_synced'] = True;
        } else {
            logger.warning("GrafanaManager: Failed to sync pending admin password");
        }
    }

    # Ensure monitoring user
    try {
        monitor_result = self.ensure_monitoring_user();
        if monitor_result.get('username') {
            result['monitoring_user_synced'] = True;
            result['monitoring_user'] = monitor_result.get('username');
        }
    } except Exception as e {
        logger.error(f"GrafanaManager: Failed to ensure monitoring user: {e}");
    }

    logger.info(f"GrafanaManager: Credential sync complete - {result}");
    return result;
}

"""Sync the admin password to Grafana after a jac-scale admin password change."""
impl GrafanaManager.sync_admin_password(new_password: str) -> bool {
    if not self._grafana_url or not self._initialized {
        logger.warning("GrafanaManager: Not initialised, cannot sync admin password");
        return False;
    }

    # Try with current cached password first
    success = self._update_grafana_admin_password(new_password);

    if not success {
        # Maybe the cached password is stale - try with persisted password
        stored = self._load_credentials('admin');
        encrypted_pw = stored.get('encrypted_password') if stored is not None else None;
        if encrypted_pw {
            try {
                import jwt;
                jwt_cfg = get_scale_config().get_jwt_config();
                jwt_secret: str = str(jwt_cfg.get('secret', ''));
                decoded: dict = dict(
                    jwt.decode(encrypted_pw, jwt_secret, algorithms=['HS256'])
                );
                persisted_pw: str = str(decoded.get('password', ''));
                if persisted_pw {
                    old_password = self._admin_password;
                    self._admin_password = persisted_pw;
                    logger.info(
                        "GrafanaManager: Retrying with persisted admin password"
                    );
                    success = self._update_grafana_admin_password(new_password);
                    if not success {
                        self._admin_password = old_password;
                    }
                }
            } except Exception as e {
                logger.warning(
                    f"GrafanaManager: Could not decrypt persisted password: {e}"
                );
            }
        }
    }

    if success {
        self._admin_password = new_password;
        # Persist encrypted password
        try {
            import jwt;
            jwt_cfg = get_scale_config().get_jwt_config();
            jwt_secret2: str = str(jwt_cfg.get('secret', ''));
            encrypted = jwt.encode(
                {'password': new_password}, jwt_secret2, algorithm='HS256'
            );
            self._persist_credentials(
                'admin',
                {
                    'grafana_user': self._admin_user,
                    'encrypted_password': encrypted,
                    'synced_at': str(datetime.datetime.now(datetime.timezone.utc))
                }
            );
        } except Exception as e {
            logger.warning(
                f"GrafanaManager: Could not encrypt password for persistence: {e}"
            );
        }
        logger.info("GrafanaManager: Admin password synced to Grafana");
    } else {
        logger.error(
            "GrafanaManager: Failed to sync admin password to Grafana. "
            "Current cached password may not match Grafana's admin password."
        );
    }
    return success;
}

"""Ensure the monitoring user exists in Grafana with Viewer role."""
impl GrafanaManager.ensure_monitoring_user -> dict[str, Any] {
    # Check if user already exists in Grafana
    existing = self._get_grafana_user(self._monitoring_user);

    if existing {
        user_id = existing.get('id');
        logger.debug(
            f"GrafanaManager: Monitoring user '{self._monitoring_user}' "
            f"already exists (id={user_id})"
        );
        # Load stored credentials
        stored = self._load_credentials('monitoring');
        if stored {
            return {
                'username': self._monitoring_user,
                'user_id': user_id,
                'status': 'existing'
            };
        }
        # User exists in Grafana but we lost the password — rotate it
        return self.rotate_monitoring_password();
    }

    # Use configured password or auto-generate
    password = self._monitoring_password;
    if not password {
        password = generate_random_password(16);
        self._monitoring_password = password;
    }

    # Create user in Grafana with Admin role
    created = self._create_grafana_user(self._monitoring_user, password, 'Admin');
    if not created {
        raise RuntimeError(
            f"Failed to create monitoring user '{self._monitoring_user}' in Grafana"
        );
    }

    user_id = created.get('id');
    now_str = str(datetime.datetime.now(datetime.timezone.utc));

    # Persist credentials
    self._persist_credentials(
        'monitoring',
        {
            'grafana_user': self._monitoring_user,
            'grafana_password': password,
            'grafana_user_id': user_id,
            'created_at': now_str,
            'updated_at': now_str
        }
    );

    logger.info(
        f"GrafanaManager: Created monitoring user '{self._monitoring_user}' "
        f"with Admin role (id={user_id})"
    );
    return {
        'username': self._monitoring_user,
        'password': password,
        'user_id': user_id,
        'status': 'created'
    };
}

"""Rotate the monitoring user's password in Grafana."""
impl GrafanaManager.rotate_monitoring_password -> dict[str, Any] {
    existing = self._get_grafana_user(self._monitoring_user);
    if not existing {
        # User doesn't exist — create it instead
        return self.ensure_monitoring_user();
    }

    user_id = existing.get('id');
    new_password = generate_random_password(16);

    success = self._update_grafana_user_password(user_id, new_password);
    if not success {
        raise RuntimeError(
            f"Failed to rotate password for monitoring user (id={user_id})"
        );
    }

    now_str = str(datetime.datetime.now(datetime.timezone.utc));
    self._persist_credentials(
        'monitoring',
        {
            'grafana_user': self._monitoring_user,
            'grafana_password': new_password,
            'grafana_user_id': user_id,
            'updated_at': now_str
        }
    );

    logger.info(f"GrafanaManager: Rotated monitoring user password (id={user_id})");
    return {
        'username': self._monitoring_user,
        'password': new_password,
        'user_id': user_id,
        'status': 'rotated'
    };
}

"""Get the stored monitoring credentials."""
impl GrafanaManager.get_monitoring_credentials -> (dict[str, Any] | None) {
    stored = self._load_credentials('monitoring');
    if stored {
        return {
            'username': stored.get('grafana_user', self._monitoring_user),
            'password': stored.get('grafana_password', ''),
            'user_id': stored.get('grafana_user_id'),
            'updated_at': stored.get('updated_at', stored.get('created_at'))
        };
    }
    return None;
}

# ── Grafana HTTP API helpers ─────────────────────────────────────────────────
"""Make an HTTP request to the Grafana API."""
impl GrafanaManager._api_request(
    method: str,
    path: str,
    data: (dict | None) = None,
    auth_user: (str | None) = None,
    auth_password: (str | None) = None
) -> (dict | None) {
    url = f"{self._grafana_url}{path}";
    user = auth_user or self._admin_user;
    password = auth_password or self._admin_password;

    # Build request
    body_bytes = json.dumps(data).encode('utf-8') if data else None;
    req = HttpRequest(url, data=body_bytes, method=method);
    req.add_header('Content-Type', 'application/json');
    req.add_header('Accept', 'application/json');

    # Basic auth
    credentials = base64.b64encode(f"{user}:{password}".encode()).decode();
    req.add_header('Authorization', f'Basic {credentials}');

    try {
        response = urlopen(req, timeout=10);
        response_body = response.read().decode('utf-8');
        if response_body {
            return json.loads(response_body);
        }
        return {'status': response.status};
    } except HTTPError as e {
        response_body = e.read().decode('utf-8') if e.fp else '';
        logger.warning(
            f"GrafanaManager API {method} {path} returned {e.code}: {response_body}"
        );
        return None;
    } except URLError as e {
        logger.warning(f"GrafanaManager API {method} {path} failed: {e.reason}");
        return None;
    } except Exception as e {
        logger.warning(f"GrafanaManager API {method} {path} error: {e}");
        return None;
    }
}

"""Check if Grafana is reachable."""
impl GrafanaManager._check_health -> bool {
    result = self._api_request('GET', '/api/health');
    return result is not None;
}

"""Verify the admin credentials work against Grafana."""
impl GrafanaManager._verify_admin_auth -> bool {
    result = self._api_request('GET', '/api/org');
    return result is not None;
}

"""Look up a Grafana user by login name."""
impl GrafanaManager._get_grafana_user(username: str) -> (dict | None) {
    return self._api_request('GET', f'/api/users/lookup?loginOrEmail={username}');
}

"""Create a new user in Grafana and set their org role."""
impl GrafanaManager._create_grafana_user(
    username: str, password: str, role: str = 'Admin'
) -> (dict | None) {
    result = self._api_request(
        'POST',
        '/api/admin/users',
        {'name': username, 'login': username, 'password': password, 'OrgId': 1}
    );
    if not result {
        return None;
    }

    user_id = result.get('id');
    if user_id {
        # Set the user's org role
        self._api_request('PATCH', f'/api/org/users/{user_id}', {'role': role});
    }
    return result;
}

"""Update a Grafana user's password by user ID."""
impl GrafanaManager._update_grafana_user_password(user_id: int, password: str) -> bool {
    result = self._api_request(
        'PUT', f'/api/admin/users/{user_id}/password', {'password': password}
    );
    return result is not None;
}

"""Update the Grafana admin user's password."""
impl GrafanaManager._update_grafana_admin_password(new_password: str) -> bool {
    result = self._api_request(
        'PUT', '/api/admin/users/1/password', {'password': new_password}
    );
    return result is not None;
}

# ── Persistence ──────────────────────────────────────────────────────────────
"""Decrypt the persisted admin password from DB using JWT secret."""
impl GrafanaManager._decrypt_persisted_admin_password -> (str | None) {
    stored = self._load_credentials('admin');
    if not stored {
        return None;
    }
    encrypted_pw = stored.get('encrypted_password');
    if encrypted_pw {
        try {
            import jwt;
            jwt_secret: str = str(get_scale_config().get_jwt_config().get('secret', ''));
            if jwt_secret {
                decoded: dict = dict(
                    jwt.decode(encrypted_pw, jwt_secret, algorithms=['HS256'])
                );
                return str(decoded.get('password', '')) or None;
            }
        } except Exception as e {
            logger.warning(
                f"GrafanaManager: Could not decrypt persisted password: {e}"
            );
        }
    }
    # Fallback for legacy unencrypted entries
    legacy_pw = stored.get('grafana_password', '') if stored else '';
    return str(legacy_pw) or None;
}

"""Persist credential data to MongoDB or in-memory store."""
impl GrafanaManager._persist_credentials(key: str, data: dict) -> None {
    doc = dict(data);
    doc['_id'] = key;
    if self._db is not None {
        try {
            existing = self._db.find_one(self._collection, {'_id': key});
            if existing {
                self._db.update_one(self._collection, {'_id': key}, {'$set': data});
            } else {
                self._db.insert_one(self._collection, doc);
            }
            return;
        } except Exception as e {
            logger.warning(
                f"GrafanaManager: MongoDB persist failed, using in-memory: {e}"
            );
        }
    }
    self._in_memory_store[key] = doc;
}

"""Load credential data from MongoDB or in-memory store."""
impl GrafanaManager._load_credentials(key: str) -> (dict | None) {
    if self._db is not None {
        try {
            doc = self._db.find_one(self._collection, {'_id': key});
            if doc {
                doc['_id'] = str(doc['_id']);
                return doc;
            }
            return None;
        } except Exception as e {
            logger.warning(
                f"GrafanaManager: MongoDB load failed, using in-memory: {e}"
            );
        }
    }
    return self._in_memory_store.get(key);
}
