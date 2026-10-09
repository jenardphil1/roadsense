# Navigation Upgrade: Google Maps Style

I have upgraded the map navigation to mirror the premium experience found in apps like Google Maps. The map now responds to your phone's physical orientation and movement smoothly.

## New Features

### 1. 🧭 Real-time Compass Rotation
The map now utilizes your phone's internal magnetometer (compass). 
- When stationary, you can spin your phone to see different parts of the map.
- I implemented a **Low-Pass Smoothing Filter** to ensure the map turns like silk, avoiding the "jitter" common in raw sensor data.

### 2. 🔄 Navigation Mode Cycling
The "Navigation" button (the arrow icon) now cycles through three distinct states:

| Icon | Mode | Description |
| :--- | :--- | :--- |
| `explore_outlined` | **Standby** | Standard map interaction. North is always up. |
| `navigation` | **Follow** | Map follows your location. It only rotates when you start driving/moving. |
| `explore` (Solid) | **Compass** | **Full Google Maps Mode.** Map follows you AND rotates live as you turn the phone. |

### 3. 🛣️ Dynamic Look-ahead
While in navigation modes, the camera doesn't just center on you—it shifts slightly forward in your direction of travel. This "look-ahead" ensures you see as much of the upcoming road as possible.

## Technical Changes
- **Dependency**: Added `flutter_compass` for hardware sensor access.
- **Optimization**: Implemented asynchronous stream management. If you manually drag the map to explore, the follow modes automatically disable to give you full control, exactly like Google Maps.
- **Safety**: Maintained the 50-meter proximity circles for pothole detection within the new navigation views.

> [!TIP]
> To get the best experience, tap the Navigation button until it shows the **solid Compass icon**. Then, point your phone toward your destination, and the map will align perfectly with the road ahead!
