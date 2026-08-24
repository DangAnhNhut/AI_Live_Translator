from fastapi.testclient import TestClient

from app.main import app


client = TestClient(app)


def test_health_allows_local_web_origin():
    response = client.get(
        "/health",
        headers={"Origin": "http://localhost:3000"},
    )

    assert response.status_code == 200
    assert (
        response.headers.get("access-control-allow-origin")
        == "http://localhost:3000"
    )
