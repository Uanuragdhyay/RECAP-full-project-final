from fastapi import FastAPI, WebSocket, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
import cv2
import numpy as np
import importlib
import os
import json
import asyncio

app = FastAPI()

# ================= CORS =================
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ================= LOAD MODEL =================
ultralytics = importlib.import_module("ultralytics")
YOLO = getattr(ultralytics, "YOLO")

# ✅ USE MEDIUM MODEL (IMPORTANT)
model = YOLO("yolov8m.pt")

VIDEO_PATH = "temp_video.mp4"


# ================= DENSITY =================
def estimate_dense_crowd(frame):
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

    edges = cv2.Canny(gray, 50, 150)
    edges = cv2.GaussianBlur(edges, (5, 5), 0)

    density = np.sum(edges > 0)
    h, w = gray.shape

    return (density / (h * w)) * 100   # return FLOAT


# ================= UPLOAD =================
@app.post("/upload")
async def upload(file: UploadFile = File(...)):
    contents = await file.read()

    with open(VIDEO_PATH, "wb") as f:
        f.write(contents)

    return {"message": "uploaded successfully"}


# ================= WEBSOCKET =================
@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()

    if not os.path.exists(VIDEO_PATH):
        await ws.send_text(json.dumps({"error": "No video uploaded"}))
        await ws.close()
        return

    cap = cv2.VideoCapture(VIDEO_PATH)

    fps = cap.get(cv2.CAP_PROP_FPS)
    if fps <= 0 or fps > 60:
        fps = 25

    frame_delay = 1 / fps

    paused = False
    running = True

    smooth_count = 0

    # ================= CONTROL =================
    async def receive_control():
        nonlocal paused, running
        try:
            while True:
                msg = await ws.receive_text()
                if msg == "pause":
                    paused = True
                elif msg == "resume":
                    paused = False
        except:
            running = False

    asyncio.create_task(receive_control())

    frame_skip = 1  # 🔥 less skip → better detection
    frame_id = 0

    try:
        while running:

            if paused:
                await asyncio.sleep(0.1)
                continue

            ret, frame = cap.read()
            if not ret:
                break

            frame_id += 1
            if frame_id % frame_skip != 0:
                continue

            try:
                frame = cv2.resize(frame, (640, 360))

                # ================= YOLO (FIXED) =================
                results = model.predict(
                    frame,
                    conf=0.4,      # 🔥 confidence threshold
                    classes=[0],   # person only
                    verbose=False
                )

                boxes = results[0].boxes

                yolo_count = len(boxes)
                heatmap = []

                for box in boxes:
                    x1, y1, x2, y2 = box.xyxy[0]
                    cx = int((x1 + x2) / 2)
                    cy = int((y1 + y2) / 2)
                    heatmap.append([cx, cy])

                # ================= DENSITY =================
                density = estimate_dense_crowd(frame)

                # ================= HYBRID =================
                if yolo_count < 5:
                    person_count = int (yolo_count * 0.7 + density * 0.2)  

                elif yolo_count < 20:
                    person_count = int(yolo_count * 1.2+ density * 0.5)    

                elif yolo_count < 25:
                    person_count = int(yolo_count * 1.2 + density * 0.4)

                else:
                    person_count = int(yolo_count + density * 1.1)

                # ================= SMOOTHING =================
                smooth_count = int(0.8 * smooth_count + 0.2 * person_count)

                smooth_count = max(0, min(smooth_count, 300))

                # ================= SEND =================
                await ws.send_text(json.dumps({
                    "count": smooth_count,
                    "heatmap": heatmap
                }))

            except Exception as e:
                print("FRAME ERROR:", e)
                continue

            await asyncio.sleep(frame_delay)

        await ws.send_text(json.dumps({"done": True}))

    except Exception as e:
        print("WS ERROR:", e)

    finally:
        cap.release()

        if os.path.exists(VIDEO_PATH):
            os.remove(VIDEO_PATH)

        await ws.close()