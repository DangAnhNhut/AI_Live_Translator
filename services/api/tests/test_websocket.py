from fastapi.testclient import TestClient

from app.main import app


client = TestClient(app)


def test_websocket_echoes_received_text():
    with client.websocket_connect("/ws/test") as websocket:
        websocket.send_text("hello")
        response = websocket.receive_text()

        assert response == "hello"
