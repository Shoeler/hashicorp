import unittest
from unittest.mock import patch, MagicMock
import os
import sys

# Stub psycopg2 so tests run without the driver installed locally
sys.modules.setdefault('psycopg2', MagicMock())

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import app

class FlaskAppTests(unittest.TestCase):
    def setUp(self):
        self.app = app.test_client()
        self.app.testing = True

    # --- /secret ---

    @patch.dict(os.environ, {"SECRET_USERNAME": "testuser", "SECRET_PASSWORD": "testpassword"})
    def test_get_secret_env(self):
        response = self.app.get('/secret')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {
            "username": "testuser",
            "password": "testpassword"
        })

    @patch.dict(os.environ, {}, clear=True)
    def test_get_secret_file_fallback(self):
        with patch("builtins.open", unittest.mock.mock_open(read_data="file_secret")) as mock_file:
            mock_file.side_effect = [
                unittest.mock.mock_open(read_data="file_user").return_value,
                unittest.mock.mock_open(read_data="file_pass").return_value
            ]
            response = self.app.get('/secret')
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json, {
                "username": "file_user",
                "password": "file_pass"
            })

    @patch.dict(os.environ, {}, clear=True)
    def test_get_secret_not_found(self):
        with patch("builtins.open", side_effect=FileNotFoundError):
            response = self.app.get('/secret')
            self.assertEqual(response.status_code, 500)
            self.assertEqual(response.json, {"error": "Secret not found"})

    # --- /dynamic-secret ---

    @patch.dict(os.environ, {"DB_USERNAME": "v-k8s-role-abc123", "DB_PASSWORD": "s3cr3t"})
    def test_get_dynamic_secret_env(self):
        response = self.app.get('/dynamic-secret')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {
            "db_username": "v-k8s-role-abc123",
            "db_password": "s3cr3t",
            "note": "Ephemeral Postgres credentials — issued by Vault, auto-rotated by VSO"
        })

    @patch.dict(os.environ, {}, clear=True)
    def test_get_dynamic_secret_not_found(self):
        response = self.app.get('/dynamic-secret')
        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.json, {"error": "Dynamic secret not available"})

    # --- /db-query ---

    @patch.dict(os.environ, {"DB_USERNAME": "v-k8s-role-abc123", "DB_PASSWORD": "s3cr3t", "DB_HOST": "localhost"})
    @patch("app.psycopg2.connect")
    def test_db_query_success(self, mock_connect):
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        mock_cursor.fetchone.return_value = ("v-k8s-role-abc123",)
        mock_cursor.fetchall.return_value = [
            (1, "widget", "A small mechanical component"),
            (2, "gadget", "An electronic device"),
        ]
        mock_conn.cursor.return_value = mock_cursor
        mock_connect.return_value = mock_conn

        response = self.app.get('/db-query')
        self.assertEqual(response.status_code, 200)
        data = response.json
        self.assertEqual(data["connected_as"], "v-k8s-role-abc123")
        self.assertEqual(len(data["products"]), 2)
        self.assertEqual(data["products"][0], {"id": 1, "name": "widget", "description": "A small mechanical component"})
        mock_connect.assert_called_once_with(
            host="localhost", port=5432, dbname="app",
            user="v-k8s-role-abc123", password="s3cr3t", connect_timeout=5
        )

    @patch.dict(os.environ, {}, clear=True)
    def test_db_query_no_credentials(self):
        response = self.app.get('/db-query')
        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.json, {"error": "Dynamic secret not available"})

    @patch.dict(os.environ, {"DB_USERNAME": "v-k8s-role-abc123", "DB_PASSWORD": "wrong", "DB_HOST": "localhost"})
    @patch("app.psycopg2.connect")
    def test_db_query_connection_error(self, mock_connect):
        mock_connect.side_effect = Exception("could not connect to server")
        response = self.app.get('/db-query')
        self.assertEqual(response.status_code, 500)
        self.assertIn("error", response.json)
        self.assertIn("could not connect", response.json["error"])

if __name__ == '__main__':
    unittest.main()
