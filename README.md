# ReCAP – Flutter Client

Cross-platform (Android, iOS, Web, Desktop) Flutter UI for the ReCAP
real-time crowd analysis platform.

## Setup

```bash
cd flutter_app
flutter pub get
```

Configure backend URL in **Settings** screen, or edit
`lib/core/constants.dart`:

```dart
const kDefaultApiBaseUrl = 'http://localhost:8000';
const kDefaultWsBaseUrl  = 'ws://localhost:8000';
```

## Run

```bash
flutter run -d chrome      # Web
flutter run -d windows     # Desktop
flutter run                # Android / iOS (with device attached)
```

## Architecture

```
lib/
  core/        # constants, theme, router
  models/      # data classes (Alert, AnalyticsPoint, Detection, FrameResult)
  services/    # ApiService (REST), WsService (WebSocket), AudioService
  providers/   # Riverpod providers (settings, stream, alerts, analytics)
  screens/     # Dashboard, Alerts, Analytics, StreamSetup, Settings
  widgets/     # CrowdCounter, HeatmapView, StatusBadge, AlertCard, ChartCard
  main.dart
```

State: **Riverpod**. Routing: **GoRouter**. Charts: **fl_chart**.

The dashboard sends webcam / video frames over WebSocket to the backend
and renders detections + heatmap overlay returned by the server.
