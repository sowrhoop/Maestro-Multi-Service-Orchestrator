import os
from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def root():
    return {"service": "A", "status": "ok"}


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8080"))
    uvicorn.run("app:app", host="0.0.0.0", port=port)

