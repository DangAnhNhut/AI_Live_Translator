from fastapi import FastAPI

from app.api.health import router as health_router
from app.core.config import settings
from app.realtime.test_socket import router as websocket_router


app = FastAPI(
    title=settings.app_name,
    version="0.1.0",
)


app.include_router(health_router)
app.include_router(websocket_router)


@app.get("/")
async def root():
    return {
        "app": settings.app_name,
        "environment": settings.app_env,
        "status": "running",
    }
