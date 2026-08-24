import logging

from fastapi import APIRouter, WebSocket, WebSocketDisconnect


router = APIRouter()
logger = logging.getLogger(__name__)


@router.websocket("/ws/test")
async def websocket_test(websocket: WebSocket):
    await websocket.accept()

    logger.info("websocket.connected route=/ws/test")

    try:
        while True:
            message = await websocket.receive_text()

            logger.info("websocket.message route=/ws/test")

            await websocket.send_text(message)

    except WebSocketDisconnect:
        logger.info("websocket.disconnected route=/ws/test")
