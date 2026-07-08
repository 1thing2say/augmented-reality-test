# Mixed Reality Test

An iOS mixed-reality sandbox: spawn virtual 3D objects into your real room, then
reach out and grab them with your bare hand. Virtual props detect and rest on
real surfaces, and a pinch of your thumb and index finger picks them up, moves
them through the air, and drops them back into the physical world. Built with
SwiftUI, ARKit, RealityKit, and the Vision framework.

## Demo

![Placing and grabbing virtual objects in a real room with a pinch gesture](output.gif)

## How it works

1. **Scan the room.** A coaching overlay guides you to sweep the camera across a
   textured horizontal surface until ARKit locks onto a plane.
2. **Spawn an object.** Pick a primitive (cube, sphere, cylinder) or a bundled
   `.usdz` model, then tap to drop it onto the detected surface, where it obeys
   gravity and rests on the plane.
3. **Grab with your hand.** Hold your hand up to the camera; the Vision framework
   tracks your hand pose. Pinch your thumb and index finger near an object to
   grab it. While grabbed its physics go kinematic so you can move it freely.
4. **Release.** Un-pinch and the object's physics go dynamic again, so it falls
   and settles back onto the real-world surfaces.

## Under the hood

A quick-glance tour of the implementation, which lives almost entirely in
`ContentView.swift`.

### The stack

- **ARKit** (`ARWorldTrackingConfiguration` with horizontal `planeDetection`)
  tracks the device and the room's surfaces.
- **RealityKit** renders the objects and runs the physics (gravity, collisions,
  kinematic vs. dynamic bodies).
- **Vision** (`VNDetectHumanHandPoseRequest`) tracks the hand from the camera
  feed to detect the pinch gesture.
- **SwiftUI** builds the UI (the model picker, HUD, and buttons), bridged to the
  AR layer through a Combine-backed view model.

### Key pieces

- **`CustomARView`** is an `ARView` subclass acting as the `ARSessionDelegate`. It
  configures world tracking, adds an `ARCoachingOverlayView` for the scan step,
  and per frame runs the hand-pose request against the camera image.
- **Placement** uses a raycast from the tap into the detected plane, then adds a
  model entity with a physics body at the hit location.
- **Grab / release** watches the pinch state: on pinch it flips the nearest
  object's physics body to kinematic and follows the hand; on release it flips it
  back to dynamic. An `@Published isPinching` flag drives both the physics and the
  on-screen color feedback via Combine.
- **Models** are discovered at runtime from the app bundle (`Bundle.main.paths(forResourcesOfType: "usdz")`)
  and offered in the picker.

### Adding models (`add_models.rb`, `fix_models.rb`)

Two Ruby helper scripts use the `xcodeproj` gem to register the `.usdz` files
under `mixed reality test/Models` into the Xcode project so they ship in the app
bundle. Run them with `ruby add_models.rb` after dropping new models in.

## Requirements

- A **physical iOS device** with ARKit support (the camera and hand tracking do
  not work in the simulator).
- **Xcode** with a recent iOS SDK.
- A free Apple developer signing identity to run on-device.

## Running it

1. Open `mixed reality test.xcodeproj` in Xcode.
2. Connect your iOS device and select it as the run destination.
3. Set your signing team under the target's Signing & Capabilities.
4. Press Run (`Cmd + R`), then grant Camera permission when prompted.
5. Scan a surface, place objects, and pinch to grab.

## Project structure

```
mixed-reality-test/
├── mixed reality test/
│   ├── ContentView.swift   # AR view, hand tracking, placement, and physics
│   ├── AppDelegate.swift
│   ├── SceneDelegate.swift
│   ├── Info.plist
│   ├── Assets.xcassets/
│   └── Models/             # Bundled .usdz models (soccer ball, teapot, biplane, drummer)
├── mixed reality test.xcodeproj/
├── add_models.rb           # Register .usdz models into the Xcode project
├── fix_models.rb           # Fix up model references in the project
└── output.gif              # Demo
```
