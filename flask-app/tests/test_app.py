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
            "password": "testpassword"
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
                "password": "file_pass"
            })

    @patch.dict(os.environ, {}, clear=True)
    def test_get_secret_not_found(self):
         with patch("builtins.open", side_effect=FileNotFoundError):
            response = self.app.get('/secret')
            self.assertEqual(response.status_code, 500)
            self.assertEqual(response.json, {"error": "Secret not found"})

if __name__ == '__main__':
    unittest.main()
