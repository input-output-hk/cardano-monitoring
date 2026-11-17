"""Re-encrypt Grafana's data keys under a new secret_key.

Grafana encrypts the secrets it keeps in its database (data source
passwords, contact point keys, OAuth tokens) with data keys, and stores
each data key encrypted under a secret_key:

- data_keys: [security] secret_key, with AES-CFB;
- secret_data_key, Grafana 13's secrets manager:
  [secrets_manager.encryption.secret_key.v1] secret_key, with AES-GCM.

Open-source Grafana can't move them to another key, so this does it
offline, with Grafana stopped. The secrets themselves aren't touched: they
stay encrypted with the same data keys.

AES-CFB has no integrity check, so a data key decrypted with the wrong key
comes out as random bytes, without an error. Before writing anything, the
current key is therefore checked by decrypting every secret in the database
that uses a data key: it is only accepted if they all come out as text.
The check command does only that; it does not inspect every legacy secret
column. Use audit after migration to check those as well.

The read-only audit command inspects Grafana 13's secret columns with both
the current and previous keys, including legacy ciphertext without a prefix.
It reports remaining old-key secrets and inconclusive checks separately.
"""

import argparse
import base64
import binascii
import contextlib
import datetime
import io
import json
import os
import secrets
import sqlite3
import string
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

try:
    from cryptography.hazmat.decrepit.ciphers.modes import CFB
except ImportError:
    from cryptography.hazmat.primitives.ciphers.modes import CFB

# Grafana's published default, which NixOS used until 26.05.
DEFAULT_KEY = b"SW2YcwTIb9zpOOhoPsMm"

SALT_LEN = 8
IV_LEN = 16
NONCE_LEN = 12
ALPHANUMERIC = string.digits + string.ascii_letters

# The tables holding data keys, with their key column and the providers
# whose keys are a secret_key.
STORES = {
    "data_keys": ("name", ("secretKey.v1", "secretKey")),
    "secret_data_key": ("uid", ("secret_key.",)),
}

# The secrets manager's values are encrypted with its data keys, which are
# named in another column rather than in the value.
NOT_SCANNED = set(STORES) | {"secret_encrypted_value"}


class RekeyError(Exception):
    pass


def b64decode_raw(data):
    return base64.b64decode(data + b"=" * (-len(data) % 4), validate=True)


def b64encode_raw(data):
    return base64.b64encode(data).rstrip(b"=")


def derive(secret, salt):
    return PBKDF2HMAC(
        algorithm=hashes.SHA256(), length=32, salt=salt, iterations=10000
    ).derive(secret)


def split_algorithm(ciphertext):
    """Split off the '*<base64 algorithm>*' prefix, as Grafana does."""
    if ciphertext[:1] != b"*":
        return "aes-cfb", ciphertext
    end = ciphertext.find(b"*", 1)
    if end == -1:
        return "aes-cfb", ciphertext[1:]
    algorithm = b64decode_raw(ciphertext[1:end]).decode()
    return algorithm or "aes-cfb", ciphertext[end + 1:]


def decrypt(ciphertext, secret):
    algorithm, payload = split_algorithm(ciphertext)
    salt, rest = payload[:SALT_LEN], payload[SALT_LEN:]
    key = derive(secret, salt)
    if algorithm == "aes-gcm":
        nonce, sealed = rest[:NONCE_LEN], rest[NONCE_LEN:]
        return AESGCM(key).decrypt(nonce, sealed, None)
    if algorithm != "aes-cfb":
        raise RekeyError(f"unknown encryption algorithm {algorithm!r}")
    iv, data = rest[:IV_LEN], rest[IV_LEN:]
    decryptor = Cipher(algorithms.AES(key), CFB(iv)).decryptor()
    return decryptor.update(data) + decryptor.finalize()


def encrypt(plaintext, secret, algorithm, salt=None, iv=None):
    """Encrypt like Grafana: the salt and IV are only given by the tests."""
    if algorithm == "aes-gcm":
        salt = salt or os.urandom(SALT_LEN)
        nonce = iv or os.urandom(NONCE_LEN)
        sealed = AESGCM(derive(secret, salt)).encrypt(nonce, plaintext, None)
        payload = salt + nonce + sealed
    elif algorithm == "aes-cfb":
        salt = salt or "".join(
            secrets.choice(ALPHANUMERIC) for _ in range(SALT_LEN)
        ).encode()
        iv = iv or os.urandom(IV_LEN)
        cipher = Cipher(algorithms.AES(derive(secret, salt)), CFB(iv))
        encryptor = cipher.encryptor()
        data = encryptor.update(plaintext) + encryptor.finalize()
        payload = salt + iv + data
    else:
        raise RekeyError(f"unknown encryption algorithm {algorithm!r}")
    return b"*" + b64encode_raw(algorithm.encode()) + b"*" + payload


def split_envelope(value):
    """Split '#<base64 data key name>#<ciphertext>', or return None."""
    if value[:1] != b"#":
        return None
    end = value.find(b"#", 1)
    if end == -1:
        return None
    try:
        name = b64decode_raw(value[1:end]).decode()
    except (binascii.Error, ValueError):
        return None
    return name, value[end + 1:]


def is_text(data):
    try:
        text = data.decode()
    except UnicodeDecodeError:
        return False
    return all(c.isprintable() or c in "\t\n\r" for c in text)


def table_exists(db, table):
    query = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
    return db.execute(query, (table,)).fetchone() is not None


def load_data_keys(db, secret):
    """Decrypt every data key: {(table, name): (algorithm, stored, key)}."""
    keys = {}
    for table, (column, providers) in STORES.items():
        if not table_exists(db, table):
            continue
        query = f"SELECT {column}, provider, encrypted_data FROM {table}"
        for name, provider, stored in db.execute(query):
            if not provider.startswith(providers):
                raise RekeyError(
                    f"{table} {name}: provider {provider!r} doesn't use a "
                    "secret_key, so this tool can't re-encrypt it"
                )
            if isinstance(stored, str):
                stored = stored.encode()
            algorithm, _ = split_algorithm(stored)
            try:
                key = decrypt(stored, secret)
            except InvalidTag:
                raise RekeyError(
                    f"{table} {name}: the current key doesn't decrypt it"
                ) from None
            if table == "data_keys" and len(key) != 16:
                raise RekeyError(f"{table} {name}: unexpected key length")
            keys[table, name] = (algorithm, stored, key)
    return keys


def candidates(value):
    """Yield the byte strings in a column value that may be secrets."""
    if isinstance(value, bytes):
        yield value
        try:
            value = value.decode()
        except UnicodeDecodeError:
            return
    stack = [value]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            stack.extend(item.values())
        elif isinstance(item, list):
            stack.extend(item)
        elif isinstance(item, str) and item.strip():
            item = item.strip()
            if item[0] in "{[":
                try:
                    stack.append(json.loads(item))
                except ValueError:
                    pass
            else:
                # Some columns hold base64 without padding.
                try:
                    yield b64decode_raw(item.encode())
                except (binascii.Error, ValueError):
                    pass


def scan(db, keys, secret):
    """Decrypt every secret that uses a data key, to check the key."""
    data_keys = {
        name: key for (table, name), (_, _, key) in keys.items()
        if table == "data_keys"
    }
    stats = Counter()
    tables = [
        name for (name,) in db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        )
        if name not in NOT_SCANNED
    ]
    for table in tables:
        for row in db.execute(f'SELECT * FROM "{table}"'):
            for value in row:
                for blob in candidates(value):
                    stats.update(classify(blob, data_keys, secret, table))
    return stats


def classify(blob, data_keys, secret, table):
    envelope = split_envelope(blob)
    if envelope:
        name, ciphertext = envelope
        if name not in data_keys:
            return ["no data key"]
        try:
            plaintext = decrypt(ciphertext, data_keys[name])
        except (InvalidTag, RekeyError, binascii.Error, ValueError):
            return ["not text", f"not text in {table}"]
        if not plaintext:
            return ["empty"]
        if not is_text(plaintext):
            return ["not text", f"not text in {table}"]
        return ["text", "long text"] if len(plaintext) >= 16 else ["text"]
    if blob[:1] == b"*":
        # Encrypted directly with the secret_key, without a data key. It
        # only counts if the current key decrypts it.
        try:
            plaintext = decrypt(blob, secret)
        except (InvalidTag, RekeyError, binascii.Error, ValueError):
            return []
        if plaintext and is_text(plaintext):
            return ["without data key", f"without data key in {table}"]
    return []


def tables_with(stats, label):
    prefix = f"{label} in "
    return ", ".join(sorted(
        key.removeprefix(prefix) for key in stats if key.startswith(prefix)
    ))


def verify(db, secret, allow_unverified=False):
    keys = load_data_keys(db, secret)
    stats = scan(db, keys, secret)
    if stats["not text"]:
        raise RekeyError(
            f"{stats['not text']} secrets don't decrypt to text with the "
            f"data keys (in {tables_with(stats, 'not text')}): is the "
            "current key right?"
        )
    if stats["without data key"]:
        raise RekeyError(
            f"{stats['without data key']} secrets are encrypted directly "
            "with the current key (in "
            f"{tables_with(stats, 'without data key')}). Move them onto data "
            "keys first with: grafana cli admin secrets-migration re-encrypt"
        )
    # AES-GCM rejects a wrong key by itself, AES-CFB doesn't.
    cfb = any(algorithm == "aes-cfb" for algorithm, _, _ in keys.values())
    if cfb and not stats["long text"] and not allow_unverified:
        raise RekeyError(
            "no secret of 16 characters or more uses the data keys, so the "
            "current key can't be confirmed. If that's expected, rerun with "
            "--allow-unverified"
        )
    return keys, stats


def rekey(db, keys, secret):
    updates = []
    for (table, name), (algorithm, stored, key) in keys.items():
        new = encrypt(key, secret, algorithm)
        if decrypt(new, secret) != key:
            raise RekeyError(f"{table} {name}: re-encryption round trip")
        updates.append((table, name, stored, new))
    with db:
        for table, name, stored, new in updates:
            column = STORES[table][0]
            cursor = db.execute(
                f"UPDATE {table} SET encrypted_data = ? "
                f"WHERE {column} = ? AND encrypted_data = ?",
                (new, name, stored),
            )
            if cursor.rowcount != 1:
                raise RekeyError(f"{table} {name}: changed while running")

    def plain(data_keys):
        return {name: key for name, (_, _, key) in data_keys.items()}

    if plain(load_data_keys(db, secret)) != plain(keys):
        raise RekeyError("the data keys don't decrypt with the new key")


def backup(db, path):
    now = datetime.datetime.now(datetime.timezone.utc)
    target = f"{path}.pre-rekey-{now:%Y%m%dT%H%M%SZ}"
    os.close(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
    copy = sqlite3.connect(target)
    try:
        db.backup(copy)
    finally:
        copy.close()
    return target


def read_key(path):
    if not path:
        raise RekeyError("the name of the key file is empty")
    # Grafana's $__file{} trims whitespace too.
    return Path(path).read_text(encoding="utf-8").strip().encode()


# From Grafana 13's pkg/services/secrets/migrator/migrator.go. Restrict
# unprefixed-ciphertext detection to secret columns: ordinary text and
# arbitrary base64 elsewhere in the database are not encrypted secrets.
AUDIT_COLUMNS = {
    "dashboard_snapshot": {"dashboard_encrypted": "raw"},
    "user_auth": dict.fromkeys((
        "o_auth_access_token", "o_auth_refresh_token", "o_auth_token_type",
        "o_auth_id_token",
    ), "base64"),
    "user_external_session": dict.fromkeys((
        "access_token", "id_token", "refresh_token", "session_id", "name_id",
    ), "base64"),
    "secrets": {"value": "base64"},
    "signing_key": {"private_key": "base64"},
    "data_source": {"secure_json_data": "map"},
    "plugin_setting": {"secure_json_data": "map"},
    "alert_configuration": {"alertmanager_configuration": "alerting"},
    "sso_setting": {"settings": "sso"},
    "resource": {"value": "provisioning"},
}
SSO_SECRET_PATTERNS = ("secret", "private", "certificate", "password",
                       "client_key")
DECRYPT_ERRORS = (InvalidTag, RekeyError, ValueError, TypeError)


@dataclass
class AuditKey:
    location: str
    candidates: dict = field(default_factory=dict)
    confirmed: set = field(default_factory=set)
    references: int = 0
    problem: str = ""


def audit_rows(db, table, required=()):
    # All the supported Grafana SQLite tables have rowids. These identify
    # rows without printing ciphertext, credentials, or unrelated columns.
    cursor = db.execute(f'SELECT rowid AS _audit_rowid, * FROM "{table}"')
    columns = [column[0] for column in cursor.description]
    if not set(required) <= set(columns):
        raise RekeyError(f"unsupported audit schema for {table}")
    for values in cursor:
        row = dict(zip(columns, values))
        yield f"{table}[rowid={row['_audit_rowid']}]", row


def audit_matches(blob, candidates):
    """Return key matches, safe diagnostics, and an empty-CFB indicator.

    GCM authenticates even empty/binary plaintext. CFB has no tag; require
    printable UTF-8 and at least 16 bytes to confirm a wrapping key. Short
    values may be accepted later if another value confirms that data key.
    """
    matches = {}
    details = []
    empty_cfb = False
    try:
        algorithm, _ = split_algorithm(blob)
        if algorithm not in ("aes-cfb", "aes-gcm"):
            raise ValueError
    except DECRYPT_ERRORS:
        return matches, "unsupported or malformed ciphertext format", False
    for label, key in candidates.items():
        try:
            plaintext = decrypt(blob, key)
        except DECRYPT_ERRORS:
            details.append(f"{label}=decryption-failed")
            continue
        if algorithm == "aes-gcm":
            matches[label] = True
            outcome = "gcm-authenticated"
        elif not plaintext:
            outcome = "cfb-empty"
            empty_cfb = True
        elif is_text(plaintext):
            matches[label] = len(plaintext) >= 16
            outcome = "cfb-long-text" if matches[label] else "cfb-short-text"
        else:
            outcome = "cfb-non-text"
        details.append(f"{label}={outcome}(bytes={len(plaintext)})")
    return matches, "; ".join(details) or "no candidate data keys", empty_cfb


class SecretAudit:
    def __init__(self, db, current, previous, report=print):
        self.db = db
        self.wrapping_keys = {"current": current, "previous": previous}
        self.report = report
        self.counts = Counter()
        self.keys = {}
        self.values = []
        self.fields = set()

    def result(self, location, status, reason=""):
        self.counts[status] += 1
        if status not in ("ok", "empty", "unreferenced-key"):
            self.report(f"{status}: {location}: {reason}")

    def load_keys(self):
        for table, (column, providers) in STORES.items():
            if not table_exists(self.db, table):
                continue
            required = (column, "provider", "encrypted_data")
            for location, row in audit_rows(self.db, table, required):
                location += ".encrypted_data"
                namespace = row.get("namespace", "")
                identity = (table, namespace, row[column])
                entry = AuditKey(location)
                self.keys[identity] = entry
                provider = row["provider"]
                if not isinstance(provider, str) or not provider.startswith(
                    providers
                ):
                    entry.problem = "unsupported wrapping provider"
                    continue  # Report as unresolved in finish().
                for label, secret in self.wrapping_keys.items():
                    try:
                        stored = row["encrypted_data"]
                        if isinstance(stored, str):
                            stored = stored.encode()
                        algorithm, _ = split_algorithm(stored)
                        key = decrypt(stored, secret)
                    except DECRYPT_ERRORS:
                        continue
                    # Both Grafana key generators use 16 random bytes.
                    if len(key) == 16:
                        entry.candidates[label] = key
                        if algorithm == "aes-gcm":
                            entry.confirmed.add(label)
                if not entry.candidates:
                    entry.problem = "neither key yields a 16-byte data key"

    def value(self, location, value, encoding="base64", reference=None):
        if value is None or value == "" or value == b"":
            self.result(location, "empty")
            return
        try:
            if not isinstance(value, (str, bytes)):
                raise ValueError
            blob = value.encode() if isinstance(value, str) else value
            if encoding == "base64":
                blob = b64decode_raw(blob)
            if reference is None and blob[:1] == b"#":
                envelope = split_envelope(blob)
                if envelope is None:
                    raise ValueError
                name, blob = envelope
                reference = ("data_keys", "", name)
        except (ValueError, TypeError):
            self.result(location, "unresolved", "invalid secret encoding")
            return
        entry = self.keys.get(reference) if reference is not None else None
        if reference is not None and entry is None:
            self.result(location, "unresolved", "referenced data key missing")
            return
        candidates = entry.candidates if entry else self.wrapping_keys
        matches, details, empty_cfb = audit_matches(blob, candidates)
        if entry:
            entry.references += 1
            entry.confirmed.update(
                k for k, strong in matches.items() if strong
            )
        self.values.append((location, entry, matches, details, empty_cfb))

    def json_fields(self, location, value, kind):
        if value is None or value == "" or value == b"":
            return
        try:
            obj = json.loads(value)
            if not isinstance(obj, dict):
                raise ValueError
        except (ValueError, TypeError):
            self.result(location, "unresolved", "invalid container JSON")
            return
        if kind == "map":
            for key, secret in obj.items():
                self.value(f"{location}[{json.dumps(key)}]", secret)
            return

        def walk(node, path):
            if isinstance(node, list):
                for index, item in enumerate(node):
                    walk(item, f"{path}[{index}]")
            elif isinstance(node, dict):
                for key, item in node.items():
                    child = f"{path}[{json.dumps(key)}]"
                    if kind == "sso" and any(
                        p in key.lower() for p in SSO_SECRET_PATTERNS
                    ):
                        self.value(child, item)
                    elif kind == "alerting" and key in (
                        "secureSettings", "secure_settings",
                    ):
                        if not isinstance(item, dict):
                            self.result(child, "unresolved", "invalid map")
                        else:
                            for field_name, secret in item.items():
                                self.value(
                                    f"{child}[{json.dumps(field_name)}]",
                                    secret,
                                )
                    else:
                        walk(item, child)

        if kind == "provisioning":
            for parts in (("spec", "github", "encryptedToken"),
                          ("status", "webhook", "encryptedSecret")):
                node, path = obj, location
                for part in parts:
                    if not isinstance(node, dict) or part not in node:
                        break
                    node = node[part]
                    path += f"[{json.dumps(part)}]"
                else:
                    self.value(path, node)
        else:
            walk(obj, location)

    def scan_fields(self):
        for table, columns in AUDIT_COLUMNS.items():
            if not table_exists(self.db, table):
                continue
            for location, row in audit_rows(self.db, table):
                if table == "resource" and (
                    row.get("group") != "provisioning.grafana.app"
                    or row.get("resource") != "repositories"
                ):
                    continue
                for column, encoding in columns.items():
                    if column not in row:
                        continue  # Optional columns vary with Grafana version.
                    self.fields.add(f"{table}.{column}")
                    path = f"{location}.{column}"
                    if encoding in ("raw", "base64"):
                        self.value(path, row[column], encoding)
                    else:
                        self.json_fields(path, row[column], encoding)
        table = "secret_encrypted_value"
        if table_exists(self.db, table):
            required = ("namespace", "data_key_id", "encrypted_data")
            for location, row in audit_rows(self.db, table, required):
                self.fields.add(f"{table}.encrypted_data")
                reference = ("secret_data_key", row["namespace"],
                             row["data_key_id"])
                self.value(f"{location}.encrypted_data", row["encrypted_data"],
                           "raw", reference)

    def finish(self):
        unresolved_keys = 0
        for entry in self.keys.values():
            if (not entry.references and not entry.confirmed
                    and not entry.problem):
                self.result(entry.location, "unreferenced-key")
            elif len(entry.confirmed) != 1:
                unresolved_keys += 1
                if entry.problem:
                    reason = entry.problem
                elif len(entry.confirmed) > 1:
                    reason = "both wrapping keys matched; ambiguous"
                elif not entry.references:
                    reason = ("no references found in audited columns; "
                              "CFB wrapping key cannot be confirmed")
                else:
                    reason = "referenced secrets do not confirm a wrapping key"
                self.result(entry.location, "unresolved",
                            f"references={entry.references}; {reason}")
            elif "previous" in entry.confirmed:
                self.result(entry.location, "old-key",
                            "data key still uses the previous wrapping key")
            else:
                self.result(entry.location, "ok")
        validated_values = 0
        for location, entry, matches, details, empty_cfb in self.values:
            confirmed = entry.confirmed if entry else {
                k for k, strong in matches.items() if strong
            }
            usable = set(matches) & confirmed
            if empty_cfb and entry and confirmed == {"current"}:
                self.result(location, "encrypted-empty",
                            "zero-byte CFB payload; referenced data key "
                            "confirmed under current key by other secrets; "
                            f"key={entry.location}")
            elif len(confirmed) != 1 or len(usable) != 1:
                if empty_cfb:
                    reason = "empty CFB payload cannot confirm a wrapping key"
                elif len(confirmed) > 1:
                    reason = "ambiguous wrapping key"
                elif entry and not confirmed:
                    reason = "referenced data key is unconfirmed"
                elif entry:
                    reason = "secret fails validation under confirmed data key"
                else:
                    reason = "direct secret cannot confirm one wrapping key"
                reference = entry.location if entry else "direct"
                self.result(location, "unresolved",
                            f"{reason}; key={reference}; {details}")
            elif "previous" in usable:
                self.result(location, "old-key",
                            "secret still requires the previous key")
            elif entry is None:
                self.result(location, "direct-current-key",
                            "secret uses the current key directly, "
                            "without a data key")
            else:
                self.result(location, "ok")
                validated_values += 1
        self.report(
            f"audit: {len(self.keys)} data keys; "
            f"{len(self.fields)} populated secret columns inspected"
        )
        referenced = sum(bool(k.references) for k in self.keys.values())
        self.report(
            "data-key references in audited columns: "
            f"referenced={referenced}; "
            f"unreferenced={len(self.keys) - referenced}"
        )
        self.report(
            f"unresolved breakdown: data-keys={unresolved_keys}; "
            f"secret-fields={self.counts['unresolved'] - unresolved_keys}"
        )
        self.report("; ".join(
            f"{status}={self.counts[status]}" for status in (
                "ok", "empty", "encrypted-empty", "unreferenced-key",
                "old-key", "direct-current-key", "unresolved",
            )
        ))
        if any(self.counts[s] for s in (
            "old-key", "direct-current-key", "unresolved",
        )):
            self.report("Migration needs investigation: see findings above.")
        elif validated_values:
            self.report("Results are consistent with a successful migration: "
                        "all nonempty audited secret payloads validate with "
                        "the current key; no old-key use was identified.")
        else:
            self.report("Migration status is inconclusive: no secret values "
                        "validated with the current key.")
        if self.counts["unreferenced-key"]:
            self.report(
                f"{self.counts['unreferenced-key']} CFB data keys have no "
                "references in audited columns; their wrapping keys remain "
                "unverified. This alone does not indicate corruption."
            )
        if self.counts["encrypted-empty"]:
            self.report("Empty CFB payloads cannot establish whether those "
                        "fields were always empty.")
        if self.counts["unreferenced-key"] or self.counts["encrypted-empty"]:
            self.report("Verification limitations remain; "
                        "audit exit status remains 1.")
        self.report("CFB validation is heuristic, not cryptographic proof. "
                    "Nothing written.")
        return self.counts


def audit_database(db, current, previous, report=print):
    if not table_exists(db, "data_keys"):
        raise RekeyError("audit requires a Grafana database with data_keys")
    audit = SecretAudit(db, current, previous, report)
    audit.load_keys()
    audit.scan_fields()
    return audit.finish()


def run_audit(args):
    current = read_key(args.current)
    previous = (DEFAULT_KEY if args.previous_default
                else read_key(args.previous))
    if not current or not previous or current == previous:
        raise RekeyError("audit requires two different, nonempty keys")
    if os.geteuid() != os.stat(args.db).st_uid:
        raise RekeyError(
            "run the audit as the database owner (e.g. sudo -u grafana)"
        )
    uri = Path(args.db).absolute().as_uri() + "?mode=ro"
    db = sqlite3.connect(uri, uri=True)
    try:
        db.execute("PRAGMA query_only = ON")
        # One consistent view of keys and secrets, including committed WAL
        # contents. Do not use immutable=1 on a live Grafana database.
        db.execute("BEGIN")
        counts = audit_database(db, current, previous)
    finally:
        db.close()
    return int(any(counts[status] for status in (
        "old-key", "direct-current-key", "unresolved",
        "unreferenced-key", "encrypted-empty",
    )))


def grafana_state():
    """grafana.service's state, as systemctl reports it; never a guess."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "grafana.service"],
            capture_output=True, text=True,
        )
    except FileNotFoundError:
        raise RekeyError(
            "systemctl isn't on PATH, so Grafana can't be confirmed stopped"
        ) from None
    state = result.stdout.strip()
    if not state:
        reason = result.stderr.strip().replace("\n", "; ")
        raise RekeyError(
            "systemctl can't tell whether Grafana is stopped: "
            + (reason or f"exit status {result.returncode}")
        )
    return state


def run(args):
    old = DEFAULT_KEY if args.from_default else read_key(args.old_file)
    # rekey requires --to; check only looks the new key over if given.
    if args.new_file is not None:
        new = read_key(args.new_file)
        if new == old:
            raise RekeyError("the new key is the same as the current one")
        if len(new) < 32 or any(c.isspace() for c in new.decode()):
            raise RekeyError(
                f"{args.new_file} doesn't look like a generated key: use 32 "
                "or more characters without spaces, e.g. openssl rand -hex 32"
            )
    if os.geteuid() != os.stat(args.db).st_uid:
        raise RekeyError(
            f"run this as the owner of {args.db} (e.g. sudo -u grafana), "
            "so that files SQLite creates keep that owner"
        )
    writing = args.command == "rekey"
    if writing:
        # Both mean no Grafana process; anything else may be one.
        state = grafana_state()
        if state not in ("inactive", "failed"):
            raise RekeyError(
                f"grafana.service is {state}: stop Grafana first with "
                "systemctl stop grafana"
            )
    uri = Path(args.db).absolute().as_uri() + ("" if writing else "?mode=ro")
    db = sqlite3.connect(uri, uri=True)
    try:
        keys, stats = verify(db, old, args.allow_unverified)
        counts = Counter(table for table, _ in keys)
        print(
            f"data keys: {counts['data_keys']} in data_keys, "
            f"{counts['secret_data_key']} in secret_data_key"
        )
        print(
            f"the current key decrypts {stats['text']} secrets to text "
            f"({stats['empty']} empty, {stats['no data key']} name a data "
            "key that no longer exists)"
        )
        if not writing:
            print("nothing written")
            return
        print(f"backup: {backup(db, args.db)}")
        rekey(db, keys, new)
        print(
            f"re-encrypted {len(keys)} data keys with the new key; start "
            "Grafana only once it is configured with that key"
        )
    finally:
        db.close()


# Grafana's own test vectors, from pkg/util/encryption_test.go and
# pkg/registry/apis/secret/encryption/cipher/provider/cipher_aesgcm_test.go.
GRAFANA_CFB = bytes([
    0x2a, 0x59, 0x57, 0x56, 0x7a, 0x4c, 0x57, 0x4e, 0x6d, 0x59, 0x67, 0x2a,
    0x7a, 0x35, 0x64, 0x57, 0x64, 0x37, 0x6b, 0x38, 0x77, 0x9a, 0xda, 0x7a,
    0x1a, 0x24, 0x42, 0x22, 0x5f, 0x3d, 0x2e, 0xf, 0xd2, 0xad, 0x53, 0xa6,
    0x69, 0x61, 0x5a, 0xe1, 0x9c, 0xc3, 0xda, 0x13, 0x80, 0xdc, 0x3e, 0x87,
    0x49, 0xbf, 0xe7, 0x2d, 0xc1, 0x8f, 0x48, 0x26, 0x45, 0xe8, 0x1b, 0xe7,
    0x51,
])
GRAFANA_GCM = bytes.fromhex(
    "61626364656667683132333435363738393031328123655291d1f5eebe34c54ba559"
    "00f68a2700818a8fda9e2921190b67271d97ce"
)


def expect(condition, what):
    if not condition:
        raise RekeyError(f"self-test failed: {what}")


def expect_refusal(action, what):
    try:
        action()
    except RekeyError:
        return
    raise RekeyError(f"self-test failed: {what} wasn't refused")


def scratch_db(secret):
    """A database laid out like Grafana's, with secrets under secret."""
    db = sqlite3.connect(":memory:")
    db.executescript("""
        CREATE TABLE data_keys (
            name TEXT PRIMARY KEY, provider TEXT, encrypted_data BLOB);
        CREATE TABLE secret_data_key (
            uid TEXT PRIMARY KEY, provider TEXT, encrypted_data BLOB);
        CREATE TABLE data_source (id INTEGER, secure_json_data TEXT);
        CREATE TABLE user_auth (id INTEGER, o_auth_refresh_token TEXT);
    """)
    key = os.urandom(16)
    db.execute(
        "INSERT INTO data_keys VALUES ('k1', 'secretKey.v1', ?)",
        (encrypt(key, secret, "aes-cfb"),),
    )
    db.execute(
        "INSERT INTO secret_data_key VALUES ('u1', 'secret_key.v1', ?)",
        (encrypt(os.urandom(16), secret, "aes-gcm"),),
    )

    def sealed(plaintext):
        envelope = b"#" + b64encode_raw(b"k1") + b"#"
        envelope += encrypt(plaintext, key, "aes-cfb")
        return base64.b64encode(envelope).decode()

    db.execute(
        "INSERT INTO data_source VALUES (1, ?)",
        (json.dumps({"basicAuthPassword": sealed(b"hunter2")}),),
    )
    db.execute(
        "INSERT INTO user_auth VALUES (1, ?)",
        (sealed(b"1//0g-a-long-oauth-refresh-token"),),
    )
    return db


def self_test():
    expect(
        decrypt(GRAFANA_CFB, b"1234") == b"my very secret secret key",
        "decrypting Grafana's AES-CFB vector",
    )
    _, payload = split_algorithm(GRAFANA_CFB)
    salt, iv = payload[:SALT_LEN], payload[SALT_LEN:SALT_LEN + IV_LEN]
    expect(
        encrypt(b"my very secret secret key", b"1234", "aes-cfb", salt, iv)
        == GRAFANA_CFB,
        "encrypting Grafana's AES-CFB vector",
    )
    sealed = encrypt(
        b"grafana unit test", b"secret here", "aes-gcm",
        b"abcdefgh", b"123456789012",
    )
    expect(
        split_algorithm(sealed) == ("aes-gcm", GRAFANA_GCM),
        "encrypting Grafana's AES-GCM vector",
    )

    new = secrets.token_hex(32).encode()
    db = scratch_db(DEFAULT_KEY)
    keys, stats = verify(db, DEFAULT_KEY)
    expect(stats["text"] == 2 and stats["long text"] == 1, "counting")
    expect_refusal(lambda: verify(db, new), "a wrong current key (AES-GCM)")
    db.execute("DELETE FROM secret_data_key")
    expect_refusal(lambda: verify(db, new), "a wrong current key (AES-CFB)")

    db = scratch_db(DEFAULT_KEY)
    keys, _ = verify(db, DEFAULT_KEY)
    rekey(db, keys, new)
    _, stats = verify(db, new)
    expect(stats["text"] == 2, "decrypting secrets after re-encryption")
    expect_refusal(lambda: verify(db, DEFAULT_KEY), "the replaced key")

    db = scratch_db(DEFAULT_KEY)
    db.execute(
        "INSERT INTO user_auth VALUES (2, ?)",
        (base64.b64encode(encrypt(b"legacy", DEFAULT_KEY, "aes-cfb"))
         .decode(),),
    )
    expect_refusal(
        lambda: verify(db, DEFAULT_KEY), "a secret without a data key"
    )

    # Grafana stores some secrets as base64 without padding.
    db = scratch_db(DEFAULT_KEY)
    db.execute(
        "UPDATE user_auth SET o_auth_refresh_token = "
        "rtrim(o_auth_refresh_token, '=')"
    )
    _, stats = verify(db, DEFAULT_KEY)
    expect(stats["long text"] == 1, "decrypting a secret without padding")

    db = scratch_db(DEFAULT_KEY)
    db.execute(
        "INSERT INTO user_auth VALUES (2, ?)",
        (base64.b64encode(encrypt(b"legacy!", DEFAULT_KEY, "aes-cfb"))
         .decode().rstrip("="),),
    )
    expect_refusal(
        lambda: verify(db, DEFAULT_KEY),
        "a secret without padding or a data key",
    )

    expect_refusal(lambda: read_key(""), "an empty key file name")
    audit_self_test()
    print("self-test passed")


def audit_self_test():
    current = b"a new wrapping key for audit tests"
    plaintext = b"a sufficiently long synthetic secret"
    messages = []

    def inspect(db):
        messages.clear()
        before = list(db.iterdump())
        counts = audit_database(db, current, DEFAULT_KEY, messages.append)
        expect(list(db.iterdump()) == before, "audit does not change data")
        output = "\n".join(messages)
        for secret in (plaintext, current, DEFAULT_KEY):
            expect(secret.decode() not in output, "no secrets in audit output")
        if any(counts[s] for s in (
            "old-key", "direct-current-key", "unresolved",
        )):
            expect("consistent with a successful migration" not in output,
                   "no reassuring summary when findings need investigation")
        return counts

    def reported(fragment):
        expect(any(fragment in message for message in messages),
               f"audit diagnostic: {fragment}")

    def direct(key, algorithm="aes-cfb", text=plaintext, legacy=False):
        blob = encrypt(text, key, algorithm)
        if legacy:
            _, blob = split_algorithm(blob)
        return base64.b64encode(blob).decode().rstrip("=")

    db = scratch_db(DEFAULT_KEY)
    expect(inspect(db)["old-key"] == 4, "old data keys and envelopes")
    keys, _ = verify(db, DEFAULT_KEY)
    rekey(db, keys, current)
    expect(inspect(db) == Counter(ok=4), "healthy migrated database")
    reported("consistent with a successful migration")

    # The former verifier misses this unprefixed, directly encrypted token.
    db.execute("INSERT INTO user_auth VALUES (2, ?)",
               (direct(DEFAULT_KEY, legacy=True),))
    verify(db, current)
    expect(inspect(db) == Counter(ok=4, **{"old-key": 1}),
           "detect legacy token after otherwise successful migration")
    db.execute("INSERT INTO user_auth VALUES (3, ?)", (direct(DEFAULT_KEY),))
    db.execute("INSERT INTO user_auth VALUES (4, ?)", (direct(current),))
    db.execute("INSERT INTO user_auth VALUES (5, ?)",
               (direct(DEFAULT_KEY, text=b"short", legacy=True),))
    db.execute("INSERT INTO user_auth VALUES (6, ?)", ("not base64!",))
    db.execute("INSERT INTO user_auth VALUES (7, ?)",
               (base64.b64encode(b"#bm9uZXhpc3RlbnQ#broken").decode(),))
    db.execute("INSERT INTO user_auth VALUES (8, ?)",
               (direct(b"an unrelated key"),))
    db.execute("INSERT INTO user_auth VALUES (9, '')")
    counts = inspect(db)
    expect(counts == Counter(ok=4, empty=1, unresolved=4,
                             **{"old-key": 2, "direct-current-key": 1}),
           "mixed legacy, direct current, short, missing and damaged secrets")
    db.close()

    db = scratch_db(current)
    db.execute("DELETE FROM user_auth")
    expect(inspect(db) == Counter(ok=1, unresolved=2),
           "short CFB reference cannot confirm its data key")
    reported("references=1; referenced secrets do not confirm")
    reported("key=data_keys[rowid=1].encrypted_data")
    reported("current=cfb-short-text(bytes=7)")
    db.execute("DELETE FROM data_source")
    expect(inspect(db) == Counter(ok=1, **{"unreferenced-key": 1}),
           "unreferenced CFB data key reported as a verification limitation")
    reported("referenced=0; unreferenced=2")
    reported("unresolved breakdown: data-keys=0; secret-fields=0")
    reported("Migration status is inconclusive")
    reported("their wrapping keys remain unverified")
    db.close()

    # Empty ciphertext payloads cannot validate a CFB wrapping key. A
    # malformed secret using a confirmed key is a different investigation.
    db = scratch_db(current)
    db.execute("INSERT INTO user_auth VALUES (2, ?)",
               (direct(current, text=b""),))
    wrapped = db.execute("SELECT encrypted_data FROM data_keys").fetchone()[0]
    key = decrypt(wrapped, current)
    blob = b"#azE#" + encrypt(b"\x00" * 32, key, "aes-cfb")
    db.execute("INSERT INTO user_auth VALUES (3, ?)",
               (base64.b64encode(blob).decode(),))
    expect(inspect(db) == Counter(ok=4, unresolved=2),
           "diagnostics preserve conservative validation")
    reported("current=cfb-empty(bytes=0)")
    reported("current=cfb-non-text(bytes=32)")
    reported("secret fails validation under confirmed data key")
    reported("unresolved breakdown: data-keys=0; secret-fields=2")
    db.execute("UPDATE data_keys SET provider = 'unsupported'")
    inspect(db)
    reported("unsupported wrapping provider")
    reported("no candidate data keys")
    db.close()

    db = scratch_db(current)
    db.execute("UPDATE data_keys SET encrypted_data = ?",
               (encrypt(os.urandom(16), current, "aes-cfb"),))
    expect(inspect(db) == Counter(ok=1, unresolved=3),
           "a rewrapped but incorrect data key cannot validate its secrets")
    db.close()

    # Every registered Grafana 13 column and each JSON layout is covered;
    # unrelated text and base64 must not become false secret candidates.
    db = scratch_db(current)
    secret = direct(DEFAULT_KEY, legacy=True)
    for table, columns in AUDIT_COLUMNS.items():
        db.execute(f'DROP TABLE IF EXISTS "{table}"')
        definitions = ", ".join(f'"{c}" TEXT' for c in columns)
        if table == "resource":
            definitions += ', "group" TEXT, resource TEXT'
        db.execute(f'CREATE TABLE "{table}" ({definitions})')
        for column, kind in columns.items():
            value = secret
            if kind == "raw":
                value = base64.b64decode(secret + "=" * (-len(secret) % 4))
            elif kind == "map":
                value = json.dumps({"password": secret})
            elif kind == "sso":
                value = json.dumps({"servers": [{"bind_password": secret}],
                                    "client_id": "ordinary text"})
            elif kind == "alerting":
                value = json.dumps({"receivers": [{"secureSettings": {
                    "password": secret}}]})
            elif kind == "provisioning":
                value = json.dumps({
                    "spec": {"github": {"encryptedToken": secret}},
                    "status": {"webhook": {"encryptedSecret": secret}},
                })
            db.execute(f'INSERT INTO "{table}" ("{column}") VALUES (?)',
                       (value,))
    db.execute('UPDATE resource SET "group" = ?, resource = ?',
               ("provisioning.grafana.app", "repositories"))
    db.execute("INSERT INTO resource VALUES ('not JSON', 'other', 'other')")
    counts = inspect(db)
    expect(counts["old-key"] == sum(map(len, AUDIT_COLUMNS.values())) + 1,
           "all supported secret columns and JSON paths scanned")
    expect(counts["unresolved"] == 0 and counts["unreferenced-key"] == 1,
           "unused CFB key is reported separately")
    db.execute("UPDATE data_source SET secure_json_data = 'not JSON'")
    expect(inspect(db)["unresolved"] == 1, "malformed JSON is reported")

    # Secrets-manager references are scoped by namespace. Authenticated
    # GCM accepts binary/empty plaintext, and detects damaged ciphertext.
    db.executescript("""
        DROP TABLE secret_data_key;
        CREATE TABLE secret_data_key (
            uid TEXT, namespace TEXT, provider TEXT, encrypted_data BLOB);
        CREATE TABLE secret_encrypted_value (
            namespace TEXT, data_key_id TEXT, encrypted_data BLOB);
    """)
    for namespace, wrapping_key in (("one", current), ("two", DEFAULT_KEY)):
        key = os.urandom(16)
        db.execute("INSERT INTO secret_data_key VALUES (?, ?, ?, ?)",
                   ("same-uid", namespace, "secret_key.v1",
                    encrypt(key, wrapping_key, "aes-gcm")))
        for text in (b"", b"\xff\x00"):
            db.execute("INSERT INTO secret_encrypted_value VALUES (?, ?, ?)",
                       (namespace, "same-uid", encrypt(text, key, "aes-gcm")))
    counts = inspect(db)
    expect(counts["ok"] == 3, "GCM binary/empty and namespaced references")
    db.execute("UPDATE secret_encrypted_value SET encrypted_data = X'00'")
    expect(inspect(db)["unresolved"] == counts["unresolved"] + 4,
           "damaged GCM ciphertext is reported")
    reported("current=decryption-failed")
    db.close()

    # Reproduce the reported production counts without any real secrets:
    # one confirmed key, 897 unreferenced keys, and seven encrypted empties.
    db = scratch_db(current)
    db.execute("DELETE FROM secret_data_key")
    wrapped = db.execute("SELECT encrypted_data FROM data_keys").fetchone()[0]
    db.executemany("INSERT INTO data_keys VALUES (?, 'secretKey.v1', ?)",
                   ((f"unused-{i}", wrapped) for i in range(897)))
    token = db.execute(
        "SELECT o_auth_refresh_token FROM user_auth"
    ).fetchone()[0]
    db.executemany("INSERT INTO user_auth VALUES (?, ?)",
                   ((i + 2, token) for i in range(221)))
    key = decrypt(wrapped, current)
    blob = b"#azE#" + encrypt(b"", key, "aes-cfb")
    db.executemany("INSERT INTO user_auth VALUES (?, ?)",
                   ((i + 223, base64.b64encode(blob).decode())
                    for i in range(7)))
    db.executemany("INSERT INTO user_auth VALUES (?, '')",
                   ((i + 230,) for i in range(98)))
    expect(inspect(db) == Counter(ok=224, empty=98,
                                  **{"encrypted-empty": 7,
                                     "unreferenced-key": 897}),
           "production-shaped results distinguish limitations from failures")
    reported("consistent with a successful migration")
    reported("referenced=1; unreferenced=897")
    reported("unresolved breakdown: data-keys=0; secret-fields=0")
    reported("audit exit status remains 1")
    expect(len(messages) < 20, "unreferenced keys summarized without row spam")
    db.close()

    db = sqlite3.connect(":memory:")
    expect_refusal(lambda: inspect(db), "unrecognized database")
    db.execute("CREATE TABLE data_keys (unrecognized TEXT)")
    expect_refusal(lambda: inspect(db), "unrecognized data-key schema")
    db.close()

    # Exercise the command's actual read-only connection against a live WAL.
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        (path / "key").write_bytes(current + b"\n")
        args = argparse.Namespace(db=str(path / "grafana.db"),
                                  current=str(path / "key"),
                                  previous_default=True, previous=None)
        source = scratch_db(current)
        source.commit()
        live = sqlite3.connect(args.db)
        source.backup(live)
        source.close()
        live.execute("PRAGMA journal_mode=WAL")
        live.execute("INSERT INTO user_auth VALUES (2, ?)", (secret,))
        live.commit()
        files = [Path(args.db), Path(args.db + "-wal")]
        before = [file.read_bytes() for file in files]
        with contextlib.redirect_stdout(io.StringIO()):
            expect(run_audit(args) == 1, "audit reads committed WAL findings")
        expect([file.read_bytes() for file in files] == before,
               "read-only audit preserves database and WAL bytes")
        live.execute("DELETE FROM user_auth WHERE id = 2")
        live.commit()
        with contextlib.redirect_stdout(io.StringIO()):
            expect(run_audit(args) == 0, "healthy audit returns zero")
        wrapped = live.execute(
            "SELECT encrypted_data FROM data_keys"
        ).fetchone()[0]
        key = decrypt(wrapped, current)
        blob = b"#azE#" + encrypt(b"", key, "aes-cfb")
        live.execute("INSERT INTO user_auth VALUES (2, ?)",
                     (base64.b64encode(blob).decode(),))
        live.commit()
        with contextlib.redirect_stdout(io.StringIO()) as output:
            expect(run_audit(args) == 1,
                   "encrypted-empty limitation preserves nonzero exit")
        expect("consistent with a successful migration" in output.getvalue(),
               "command summary qualifies successful migration")
        live.close()


def main():
    parser = argparse.ArgumentParser(
        prog="grafana-rekey",
        description="Re-encrypt Grafana's data keys under a new secret_key.",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser(
        "self-test",
        help="check the encryption against Grafana's test vectors",
    )
    audit = commands.add_parser(
        "audit", help="read-only audit using current and previous keys",
    )
    audit.add_argument("--db", required=True, help="grafana.db")
    audit.add_argument("--current", required=True, metavar="FILE",
                       help="file holding the current secret_key")
    previous = audit.add_mutually_exclusive_group(required=True)
    previous.add_argument("--previous", metavar="FILE",
                          help="file holding the previous secret_key")
    previous.add_argument("--previous-default", action="store_true",
                          help="the previous key was Grafana's public default")
    for name, text in (
        ("check", "check the current key against the database; change "
                  "nothing"),
        ("rekey", "back up the database, then re-encrypt its data keys"),
    ):
        command = commands.add_parser(name, help=text)
        command.add_argument("--db", required=True, help="grafana.db")
        old = command.add_mutually_exclusive_group(required=True)
        old.add_argument(
            "--from", dest="old_file", metavar="FILE",
            help="file holding the current secret_key",
        )
        old.add_argument(
            "--from-default", action="store_true",
            help="the current secret_key is Grafana's public default",
        )
        command.add_argument(
            "--to", dest="new_file", metavar="FILE",
            required=name == "rekey",
            help="file holding the new secret_key",
        )
        command.add_argument(
            "--allow-unverified", action="store_true",
            help="go ahead when no secret can confirm the current key",
        )
    args = parser.parse_args()
    try:
        if args.command == "self-test":
            self_test()
        elif args.command == "audit":
            return run_audit(args)
        else:
            run(args)
    except (RekeyError, OSError, sqlite3.Error) as error:
        print(f"grafana-rekey: {error}", file=sys.stderr)
        return 2 if args.command == "audit" else 1


if __name__ == "__main__":
    sys.exit(main())
