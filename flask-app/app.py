from flask import Flask, jsonify
import os

app = Flask(__name__)

@app.route('/secret', methods=['GET'])
def get_secret():
    username = os.environ.get('SECRET_USERNAME')
    password = os.environ.get('SECRET_PASSWORD')

    if not username or not password:
        # Fallback to file reading if env vars are not set
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

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
