from typing import Annotated

from fastapi import APIRouter, Depends, WebSocket
from starlette.websockets import WebSocketDisconnect

from app.realtime.session_hub import SessionHub, get_session_hub


router = APIRouter()


@router.websocket("/ws/sessions/{session_id}/viewer")
async def websocket_session_viewer(
    websocket: WebSocket,
    session_id: str,
    session_hub: Annotated[SessionHub, Depends(get_session_hub)],
) -> None:
    await websocket.accept()
    try:
        await session_hub.join_viewer(session_id, websocket)
        while True:
            message = await websocket.receive()
            if message["type"] == "websocket.disconnect":
                break
    except WebSocketDisconnect:
        pass
    finally:
        await session_hub.leave_viewer(session_id, websocket)
