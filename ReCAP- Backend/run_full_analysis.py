import importlib
import sys
import cv2
import numpy as np
from pathlib import Path

VIDEO_IN = "preview_uploaded.mp4"
OUT_VIDEO = "annotated_heatmap_output.mp4"
MAX_FRAMES = 500
MODEL_PATH = "yolov8n.pt"

# =========================================================
# ✅ DENSE CROWD ESTIMATION (FINAL WORKING)
# =========================================================
def estimate_dense_crowd(frame):
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

    edges = cv2.Canny(gray, 50, 150)
    edges = cv2.GaussianBlur(edges, (5, 5), 0)

    density = np.sum(edges > 0)

    h, w = gray.shape
    density_ratio = density / (h * w)

    count = int(density_ratio * 1200)  # tuned multiplier

    return count


# =========================================================
# HEATMAP FUNCTION
# =========================================================
def generate_heatmap_from_boxes(frame_shape, boxes, radius=40, sigma=25):
    h, w = frame_shape[:2]
    heat = np.zeros((h, w), dtype=np.uint8)

    for b in boxes:
        try:
            x1, y1, x2, y2 = map(int, b[:4])
        except:
            continue

        cx = int((x1 + x2) / 2)
        cy = int((y1 + y2) / 2)
        cv2.circle(heat, (cx, cy), radius, 255, -1)

    if heat.max() > 0:
        heat = cv2.GaussianBlur(heat, (0, 0), sigmaX=sigma)
        heat = np.uint8(255 * (heat / heat.max()))

    return cv2.applyColorMap(heat, cv2.COLORMAP_JET)


# =========================================================
# LOAD YOLO
# =========================================================
ultralytics = importlib.import_module("ultralytics")
YOLO = getattr(ultralytics, "YOLO")

if not Path(VIDEO_IN).exists():
    print("Video not found")
    sys.exit()

cap = cv2.VideoCapture(VIDEO_IN)

fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

out = cv2.VideoWriter(
    OUT_VIDEO,
    cv2.VideoWriter_fourcc(*"mp4v"),
    fps,
    (w * 2, h)
)

print("Loading YOLO...")
model = YOLO(MODEL_PATH)

frame_idx = 0

while frame_idx < MAX_FRAMES:
    ret, frame = cap.read()
    if not ret:
        break

    results = model(frame, verbose=False, classes=0)
    r = results[0]

    annotated = r.plot()

    try:
        boxes = r.boxes.xyxy.cpu().numpy()
    except:
        boxes = []

    yolo_count = len(boxes)

    # 🔥 SMART SWITCH
    if yolo_count < 25:
        dense_count = estimate_dense_crowd(frame)
        count = max(dense_count, yolo_count)
    else:
        count = yolo_count

    cv2.putText(
        annotated,
        f"Count: {count}",
        (20, 50),
        cv2.FONT_HERSHEY_SIMPLEX,
        1.2,
        (0, 0, 255),
        3
    )

    heat = generate_heatmap_from_boxes(annotated.shape, boxes)

    combined = np.hstack((annotated, heat))
    out.write(combined)

    frame_idx += 1

cap.release()
out.release()

print("DONE")