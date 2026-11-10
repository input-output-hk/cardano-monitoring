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
The check command does only that, so it also confirms afterwards that the
database decrypts with the new key.
"""

import argparse
import base64
import binascii
import datetime
import json
import os
import secrets
import sqlite3
import string
import subprocess
import sys
from collections import Counter
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
        (encrypt(os.urandom(32), secret, "aes-gcm"),),
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
    print("self-test passed")


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
        else:
            run(args)
    except (RekeyError, OSError, sqlite3.Error) as error:
        sys.exit(f"grafana-rekey: {error}")


if __name__ == "__main__":
    main()
