from flask import Flask, jsonify
import os
from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.x509.oid import NameOID

app = Flask(__name__)

@app.route('/secret', methods=['GET'])
def get_secret():
    username = os.environ.get('SECRET_USERNAME')
    password = os.environ.get('SECRET_PASSWORD')
    cert = None

    if not username or not password:
        # Fallback to file reading if env vars are not set
        try:
            with open('/etc/secrets/username', 'r') as f:
                username = f.read().strip()
            with open('/etc/secrets/password', 'r') as f:
                password = f.read().strip()
        except FileNotFoundError:
            return jsonify({"error": "Secret not found"}), 500

    cert_info = "Certificate not found"
    try:
        if os.path.exists('/etc/certs/tls.crt'):
            with open('/etc/certs/tls.crt', 'rb') as f:
                cert_data = f.read()
                cert = x509.load_pem_x509_certificate(cert_data, default_backend())
                # Get the Common Name and Serial Number
                for attribute in cert.subject:
                    if attribute.oid == NameOID.COMMON_NAME:
                        cert_info = f"CN={attribute.value}"
                        break
        else:
            cert_info = "Certificate file not found at /etc/certs/tls.crt"

    except Exception as e:
        cert_info = f"Error reading certificate: {str(e)}"
    serialNumber = hex(cert.serial_number)

    return jsonify({
        "username": username,
        "password": password,
        "certificate": cert_info,
        "serial_number": serialNumber
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
