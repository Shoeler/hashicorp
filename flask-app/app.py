from flask import Flask, jsonify
import os
import psycopg2

app = Flask(__name__)

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
    username = os.environ.get('DB_USERNAME')
    password = os.environ.get('DB_PASSWORD')
    host = os.environ.get('DB_HOST', 'postgres.default.svc')

    if not username or not password:
        return jsonify({"error": "Dynamic secret not available"}), 500

    try:
        conn = psycopg2.connect(
            host=host,
            port=5432,
            dbname='app',
            user=username,
            password=password,
            connect_timeout=5,
        )
        cur = conn.cursor()
        cur.execute("SELECT current_user")
        connected_as = cur.fetchone()[0]
        cur.execute("SELECT id, name, description FROM products ORDER BY id")
        products = [
            {"id": row[0], "name": row[1], "description": row[2]}
            for row in cur.fetchall()
        ]
        cur.close()
        conn.close()
        return jsonify({
            "connected_as": connected_as,
            "products": products,
            "note": "Query executed with Vault-issued ephemeral Postgres credentials"
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
