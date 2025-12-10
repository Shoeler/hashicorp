import unittest
from unittest.mock import patch
import os
import sys

# Add the parent directory to sys.path to import app
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import app

class FlaskAppTests(unittest.TestCase):
    def setUp(self):
        self.app = app.test_client()
        self.app.testing = True

    @patch.dict(os.environ, {"SECRET_USERNAME": "testuser", "SECRET_PASSWORD": "testpassword"})
    def test_get_secret_env(self):
        response = self.app.get('/secret')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {
            "username": "testuser",
            "password": "testpassword",
            "certificate": "Certificate file not found at /etc/certs/tls.crt"
        })

    @patch.dict(os.environ, {}, clear=True)
    def test_get_secret_file_fallback(self):
        # Mocking open is a bit tricky with patch, doing it inside the test method
        with patch("builtins.open", unittest.mock.mock_open(read_data="file_secret")) as mock_file:
            # We need to return different values for different files
            # Since open is called twice, we can use side_effect
            mock_file.side_effect = [
                unittest.mock.mock_open(read_data="file_user").return_value,
                unittest.mock.mock_open(read_data="file_pass").return_value
            ]

            response = self.app.get('/secret')
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json, {
                "username": "file_user",
                "password": "file_pass",
                "certificate": "Certificate file not found at /etc/certs/tls.crt"
            })

    @patch.dict(os.environ, {}, clear=True)
    def test_get_secret_not_found(self):
         with patch("builtins.open", side_effect=FileNotFoundError):
            response = self.app.get('/secret')
            self.assertEqual(response.status_code, 500)
            self.assertEqual(response.json, {"error": "Secret not found"})

    @patch.dict(os.environ, {"SECRET_USERNAME": "testuser", "SECRET_PASSWORD": "testpassword"})
    def test_get_secret_with_certificate(self):
        # Create a self-signed certificate for testing
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives import serialization
        import datetime

        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = issuer = x509.Name([
            x509.NameAttribute(x509.NameOID.COMMON_NAME, u"test.example.com"),
        ])
        cert = x509.CertificateBuilder().subject_name(
            subject
        ).issuer_name(
            issuer
        ).public_key(
            key.public_key()
        ).serial_number(
            x509.random_serial_number()
        ).not_valid_before(
            datetime.datetime.utcnow()
        ).not_valid_after(
            datetime.datetime.utcnow() + datetime.timedelta(days=10)
        ).add_extension(
            x509.SubjectAlternativeName([x509.DNSName(u"localhost")]),
            critical=False,
        ).sign(key, hashes.SHA256())

        cert_pem = cert.public_bytes(serialization.Encoding.PEM)

        with patch("os.path.exists") as mock_exists, \
             patch("builtins.open", unittest.mock.mock_open(read_data=cert_pem)) as mock_file:

            # Ensure /etc/certs/tls.crt is considered existing
            def side_effect(path):
                return path == '/etc/certs/tls.crt'
            mock_exists.side_effect = side_effect

            response = self.app.get('/secret')
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json, {
                "username": "testuser",
                "password": "testpassword",
                "certificate": "CN=test.example.com"
            })

if __name__ == '__main__':
    unittest.main()
