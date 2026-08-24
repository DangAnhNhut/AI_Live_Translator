from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.health import router as health_router
from app.core.config import settings
from app.realtime.test_socket import router as websocket_router


app = FastAPI(
    title=settings.app_name,
    version="0.1.0",
)


app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:3000",
        "http://127.0.0.1:3000",
    ],
    allow_credentials=True,
    allow_methods=["GET"],
    allow_headers=["*"],
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
