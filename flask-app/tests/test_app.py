import unittest
from unittest.mock import patch, MagicMock
import os
import sys

# Stub psycopg2 so tests run without the driver installed locally
sys.modules.setdefault('psycopg2', MagicMock())
sys.modules.setdefault('psycopg2.pool', MagicMock())

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import app as app_module
from app import app


class FlaskAppTests(unittest.TestCase):
    def setUp(self):
        self.app = app.test_client()
        self.app.testing = True
        # Reset global state between tests
        app_module._pool = None
        app_module._queries_served = 0

    def _make_mock_pool(self, connected_as="v-k8s-role-abc123"):
        mock_pool = MagicMock()
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        mock_cursor.fetchone.return_value = (connected_as,)
        mock_cursor.fetchall.return_value = [
            (1, "widget", "A small mechanical component"),
            (2, "gadget", "An electronic device"),
        ]
        mock_conn.cursor.return_value = mock_cursor
        mock_pool.getconn.return_value = mock_conn
        mock_pool.minconn = 2
        mock_pool.maxconn = 10
        mock_pool._pool = [mock_conn]
        return mock_pool

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
    def test_db_query_success(self):
        mock_pool = self._make_mock_pool("v-k8s-role-abc123")
        with patch.object(app_module, '_get_pool', return_value=mock_pool):
            response = self.app.get('/db-query')
        self.assertEqual(response.status_code, 200)
        data = response.json
        self.assertEqual(data["connected_as"], "v-k8s-role-abc123")
        self.assertEqual(len(data["products"]), 2)
        self.assertEqual(data["products"][0]["name"], "widget")
        mock_pool.putconn.assert_called_once()

    @patch.dict(os.environ, {}, clear=True)
    def test_db_query_no_credentials(self):
        response = self.app.get('/db-query')
        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.json, {"error": "Dynamic secret not available"})

    @patch.dict(os.environ, {"DB_USERNAME": "v-k8s-role-abc123", "DB_PASSWORD": "wrong", "DB_HOST": "localhost"})
    def test_db_query_connection_error(self):
        mock_pool = MagicMock()
        mock_pool.getconn.side_effect = Exception("could not connect to server")
        with patch.object(app_module, '_get_pool', return_value=mock_pool):
            response = self.app.get('/db-query')
        self.assertEqual(response.status_code, 500)
        self.assertIn("could not connect", response.json["error"])

    @patch.dict(os.environ, {"DB_USERNAME": "v-k8s-role-abc123", "DB_PASSWORD": "s3cr3t", "DB_HOST": "localhost"})
    def test_db_query_putconn_called_on_error(self):
        mock_pool = MagicMock()
        mock_conn = MagicMock()
        mock_conn.cursor.side_effect = Exception("cursor error")
        mock_pool.getconn.return_value = mock_conn
        with patch.object(app_module, '_get_pool', return_value=mock_pool):
            response = self.app.get('/db-query')
        self.assertEqual(response.status_code, 500)
        mock_pool.putconn.assert_called_once_with(mock_conn)

    # --- /pool-status ---

    @patch.dict(os.environ, {"DB_USERNAME": "v-k8s-role-abc123", "DB_PASSWORD": "s3cr3t", "POD_NAME": "flask-app-abc-xyz"})
    def test_pool_status_success(self):
        mock_pool = self._make_mock_pool()
        with patch.object(app_module, '_get_pool', return_value=mock_pool):
            response = self.app.get('/pool-status')
        self.assertEqual(response.status_code, 200)
        data = response.json
        self.assertEqual(data["pod"], "flask-app-abc-xyz")
        self.assertEqual(data["vault_role"], "v-k8s-role-abc123")
        self.assertEqual(data["pool_min"], 2)
        self.assertEqual(data["pool_max"], 10)
        self.assertIn("connections_available", data)
        self.assertIn("queries_served", data)

    @patch.dict(os.environ, {"DB_USERNAME": "v-k8s-role-abc123", "DB_PASSWORD": "s3cr3t", "DB_HOST": "localhost"})
    def test_db_query_increments_counter(self):
        mock_pool = self._make_mock_pool()
        with patch.object(app_module, '_get_pool', return_value=mock_pool):
            self.app.get('/db-query')
            self.app.get('/db-query')
        self.assertEqual(app_module._queries_served, 2)

    @patch.dict(os.environ, {}, clear=True)
    def test_pool_status_no_credentials(self):
        response = self.app.get('/pool-status')
        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.json, {"error": "Dynamic secret not available"})


if __name__ == '__main__':
    unittest.main()
