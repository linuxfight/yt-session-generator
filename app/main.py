from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse, PlainTextResponse, RedirectResponse
import logging
import uvicorn
import asyncio
import sys

from app.extractor import PotokenExtractor

try:
    import uvloop
except ImportError:
    uvloop = None

logger = logging.getLogger("server")

app = FastAPI()


@app.middleware("http")
async def handle_headless_error(request: Request, call_next):
    try:
        return await call_next(request)
    except Exception as e:
        if "HEADLESS-1" in str(e):
            logger.warning("Ignoring HEADLESS-1 config error, continuing operation")
            return PlainTextResponse("Service available", status_code=200)
        raise


@app.get("/")
async def root():
    return RedirectResponse(url="/token")


@app.get("/token")
async def get_token(request: Request):
    extractor: PotokenExtractor = request.app.state.potoken_extractor
    token = extractor.get()
    if token is None:
        return PlainTextResponse(
            content="Token has not yet been generated, try again later.",
            status_code=503,
        )
    return JSONResponse(content=token.to_json())


@app.get("/update")
async def request_update(request: Request):
    extractor: PotokenExtractor = request.app.state.potoken_extractor
    accepted = extractor.request_update()
    if accepted:
        message = "Update request accepted, new token will be generated soon."
    else:
        message = "Update has already been requested, new token will be generated soon."
    return PlainTextResponse(content=message)


@app.exception_handler(404)
async def not_found_handler(request: Request, exc: HTTPException):
    return PlainTextResponse("Not Found", status_code=404)


async def main(
    update_interval: int,
    bind_address: str,
    port: int,
    browser_path: str,
) -> None:
    loop = asyncio.get_running_loop()
    potoken_extractor = PotokenExtractor(
        loop=loop,
        update_interval=update_interval,
        browser_path=browser_path,
    )

    app.state.potoken_extractor = potoken_extractor
    extractor_task = asyncio.create_task(potoken_extractor.run())

    uvicorn_config = uvicorn.Config(
        app=app,
        host=bind_address,
        port=port,
        loop="asyncio",
        lifespan="on",
        log_level="info",
    )
    server = uvicorn.Server(config=uvicorn_config)
    server_task = asyncio.create_task(server.serve())

    try:
        done, _ = await asyncio.wait(
            {extractor_task, server_task},
            return_when=asyncio.FIRST_EXCEPTION,
        )

        for task in done:
            if task.cancelled():
                continue
            if exc := task.exception():
                raise exc

    except (KeyboardInterrupt, asyncio.CancelledError):
        logger.info("Shutdown requested - stopping...")
    finally:
        if not extractor_task.done():
            extractor_task.cancel()
            try:
                await extractor_task
            except asyncio.CancelledError:
                pass

        if not server.should_exit:
            server.should_exit = True
            try:
                await server_task
            except asyncio.CancelledError:
                pass

        logger.info("Cleanup complete. Exiting.")


if __name__ == "__main__":
    # Remove deprecated SafeChildWatcher (no longer needed in Python 3.8+)
    # uvloop handles async child processes properly

    if uvloop is not None:
        uvloop.install()
        logger.info("uvloop installed as the event loop policy.")

    update_interval = 300
    bind_address = "0.0.0.0"
    port = 8080
    browser_path = "/usr/bin/chromium"

    # Set XDG_RUNTIME_DIR to prevent wlr renderer errors
    import os
    if not os.environ.get("XDG_RUNTIME_DIR"):
        os.environ["XDG_RUNTIME_DIR"] = "/tmp/runtime"
        os.makedirs("/tmp/runtime", exist_ok=True)
        logger.info("Set XDG_RUNTIME_DIR to /tmp/runtime")

    logger.info(f"Starting web-server at {bind_address}:{port}")

    try:
        asyncio.run(
            main(
                update_interval=update_interval,
                bind_address=bind_address,
                port=port,
                browser_path=browser_path,
            )
        )
    except Exception as e:
        logger.error(f"Fatal error in startup: {e}", exc_info=True)
        sys.exit(1)
