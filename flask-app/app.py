from flask import Flask, jsonify
import os
import threading
import psycopg2
from psycopg2 import pool as pg_pool

app = Flask(__name__)

# Pool is initialised once per pod on first use, using the env vars present at
# startup.  When VSO rotates credentials it triggers a rollout restart, so each
# new pod always starts with a fresh pool bound to the current Vault lease.
_pool = None
_pool_lock = threading.Lock()
_queries_served = 0
_queries_lock = threading.Lock()


def _get_pool():
    global _pool
    if _pool is None:
        with _pool_lock:
            if _pool is None:
                username = os.environ.get('DB_USERNAME')
                password = os.environ.get('DB_PASSWORD')
                if not username or not password:
                    return None
                _pool = pg_pool.ThreadedConnectionPool(
                    minconn=int(os.environ.get('DB_POOL_MIN', 2)),
                    maxconn=int(os.environ.get('DB_POOL_MAX', 10)),
                    host=os.environ.get('DB_HOST', 'postgres.default.svc'),
                    port=5432,
                    dbname='app',
                    user=username,
                    password=password,
                    connect_timeout=5,
                )
    return _pool


@app.route('/secret', methods=['GET'])
def get_secret():
    username = os.environ.get('SECRET_USERNAME')
    password = os.environ.get('SECRET_PASSWORD')

    if not username or not password:
        try:
            with open('/etc/secrets/username', 'r') as f:
                username = f.read().strip()
            with open('/etc/secrets/password', 'r') as f:
                password = f.read().strip()
        except FileNotFoundError:
            return jsonify({"error": "Secret not found"}), 500

    return jsonify({
        "username": username,
        "password": password
    })


@app.route('/dynamic-secret', methods=['GET'])
def get_dynamic_secret():
    username = os.environ.get('DB_USERNAME')
    password = os.environ.get('DB_PASSWORD')

    if not username or not password:
        return jsonify({"error": "Dynamic secret not available"}), 500

    return jsonify({
        "db_username": username,
        "db_password": password,
        "note": "Ephemeral Postgres credentials — issued by Vault, auto-rotated by VSO"
    })


@app.route('/db-query', methods=['GET'])
def db_query():
    if not os.environ.get('DB_USERNAME') or not os.environ.get('DB_PASSWORD'):
        return jsonify({"error": "Dynamic secret not available"}), 500

    p = _get_pool()
    if p is None:
        return jsonify({"error": "Dynamic secret not available"}), 500

    global _queries_served
    conn = None
    try:
        conn = p.getconn()
        cur = conn.cursor()
        cur.execute("SELECT current_user")
        connected_as = cur.fetchone()[0]
        cur.execute("SELECT id, name, description FROM products ORDER BY id")
        products = [
            {"id": row[0], "name": row[1], "description": row[2]}
            for row in cur.fetchall()
        ]
        cur.close()
        with _queries_lock:
            _queries_served += 1
        return jsonify({
            "connected_as": connected_as,
            "products": products,
            "note": "Query executed with Vault-issued ephemeral Postgres credentials"
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    finally:
        if conn is not None:
            p.putconn(conn)


@app.route('/pool-status', methods=['GET'])
def pool_status():
    username = os.environ.get('DB_USERNAME')
    if not username or not os.environ.get('DB_PASSWORD'):
        return jsonify({"error": "Dynamic secret not available"}), 500

    p = _get_pool()
    if p is None:
        return jsonify({"error": "Dynamic secret not available"}), 500

    return jsonify({
        "pod": os.environ.get('POD_NAME', 'unknown'),
        "vault_role": username,
        "pool_min": p.minconn,
        "pool_max": p.maxconn,
        "connections_available": len(p._pool),
        "queries_served": _queries_served,
        "note": "Each replica maintains its own pool; all replicas share the same Vault-issued credential"
    })


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
