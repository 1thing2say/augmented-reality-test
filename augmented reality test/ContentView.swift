//
//  ContentView.swift
//  augmented reality test
//
//  Created by my computer on 6/2/26.
//

import SwiftUI
import RealityKit
import ARKit
import Vision
import Combine // Import Combine to connect the ViewModel to the ARView

// MARK: - Component For Grabbing

/// A component that marks an entity as being grabbable.
struct GrabbableComponent: Component {}


// MARK: - Model Definitions

/// An enum to represent the different types of models the user can place.
enum ModelType: String, CaseIterable, Identifiable {
    case cube = "Cube"
    case sphere = "Sphere"
    case cylinder = "Cylinder"
    case custom = "Custom Model"
    
    var id: String { self.rawValue }
}


// MARK: - ViewModel

/// An object to communicate state from the ARView to the SwiftUI HUD.
class ARViewModel: ObservableObject {
    @Published var handDetected: Bool = false
    @Published var isPinching: Bool = false
    @Published var selectedModelType: ModelType = .cube
    @Published var isCoachingActive: Bool = true // Tracks coaching overlay state
    
    /// A subject to broadcast requests to place an object.
    let placeObjectSubject = PassthroughSubject<Void, Never>()
}


// MARK: - SwiftUI Views

/// The main SwiftUI view. It will host our AR experience and the HUD.
struct ContentView : View {
    // Create a state object for our ViewModel.
    @StateObject private var viewModel = ARViewModel()
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // The AR View that renders the scene.
            ARViewContainer(viewModel: viewModel)
                .edgesIgnoringSafeArea(.all)
            
            // A VStack to layer the HUD on top and controls on the bottom.
            VStack {
                HUDView(viewModel: viewModel)
                Spacer()
                
                // Only show the placement UI when coaching is finished.
                if !viewModel.isCoachingActive {
                    // A new button to trigger object placement.
                    Button(action: {
                        viewModel.placeObjectSubject.send()
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                            .padding(20)
                            .background(Color.blue)
                            .clipShape(Circle())
                            .shadow(radius: 5, y: 2)
                    }
                    .padding(.bottom)

                    ModelPickerView(viewModel: viewModel)
                        .padding(.bottom, 30) // Add padding from the bottom edge
                }
            }
        }
    }
}

/// A SwiftUI view that displays the status from the ARViewModel.
struct HUDView: View {
    @ObservedObject var viewModel: ARViewModel
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(viewModel.handDetected ? "Hand Detected" : "Scanning for Hand...")
                .font(.headline)
                .foregroundColor(.white)
            
            Text("Pinching: \(viewModel.isPinching ? "YES" : "NO")")
                .font(.subheadline)
                .foregroundColor(viewModel.isPinching ? .green : .white)
        }
        .frame(maxWidth: .infinity, alignment: .leading) // Ensure it aligns left
        .padding()
        .background(Color.black.opacity(0.5))
        .cornerRadius(10)
        .padding([.top, .horizontal])
    }
}

/// A new SwiftUI view for the model selection picker.
struct ModelPickerView: View {
    @ObservedObject var viewModel: ARViewModel
    
    var body: some View {
        Picker("Select a Model", selection: $viewModel.selectedModelType) {
            ForEach(ModelType.allCases) { type in
                Text(type.rawValue).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .padding()
        .background(Color.black.opacity(0.5))
        .cornerRadius(15)
        .padding(.horizontal)
    }
}


// MARK: - ARView Implementation

/// A UIViewRepresentable to bridge UIKit's ARView into a SwiftUI view.
struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: ARViewModel
    
    func makeUIView(context: Context) -> CustomARView {
        // Pass the ViewModel to our custom ARView.
        return CustomARView(frame: .zero, viewModel: viewModel)
    }
    
    func updateUIView(_ uiView: CustomARView, context: Context) {}
}

/// This is our custom ARView class. It handles the AR session,
/// sets up the scene, and processes camera frames for hand tracking.
class CustomARView: ARView, ARSessionDelegate, ARCoachingOverlayViewDelegate {
    
    private let viewModel: ARViewModel
    private var cancellables: Set<AnyCancellable> = []
    
    private let coachingOverlay = ARCoachingOverlayView()
    
    private var jointEntities: [VNHumanHandPoseObservation.JointName: ModelEntity] = [:]
    private let handAnchor = AnchorEntity()
    
    private var grabbedObject: ModelEntity?
    private var latestHandObservation: VNHumanHandPoseObservation?
    
    private var lastPlacedObject: ModelEntity?
    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    
    /// Tracks invisible collision planes created from detected ARPlaneAnchors.
    private var planeEntities: [UUID: AnchorEntity] = [:]
    
    /// A flag to prevent processing multiple frames at once.
    private var isProcessingFrame = false
    /// A CIContext for converting CVPixelBuffers to CGImages.
    private let ciContext = CIContext()

    init(frame frameRect: CGRect, viewModel: ARViewModel) {
        self.viewModel = viewModel
        super.init(frame: frameRect)
        
        // Note: sceneUnderstanding.physics only works with LiDAR scene reconstruction.
        // We create our own collision planes from detected ARPlaneAnchors instead.
        
        session.delegate = self
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.frameSemantics.insert(.personSegmentation)
        session.run(config)
        
        setupScene()
        setupCoachingOverlay()
        setupGestures()
        subscribeToViewModel()
    }
    
    @MainActor required dynamic init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @MainActor @preconcurrency required dynamic init(frame frameRect: CGRect) {
        fatalError("init(frame:) has not been implemented")
    }
    
    private func setupScene() {
        self.scene.addAnchor(handAnchor)
    }
    
    /// Configures and adds the ARCoachingOverlayView to the view hierarchy.
    private func setupCoachingOverlay() {
        coachingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.addSubview(coachingOverlay)
        coachingOverlay.delegate = self
        coachingOverlay.session = self.session
        coachingOverlay.goal = .horizontalPlane
    }

    private func setupGestures() {
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapRecognizer.cancelsTouchesInView = false // Don't block SwiftUI button taps
        self.addGestureRecognizer(tapRecognizer)
    }
    
    private func subscribeToViewModel() {
        // Color feedback when pinching
        viewModel.$isPinching
            .removeDuplicates()
            .sink { [weak self] isPinching in
                guard let self = self else { return }

                let targetModel: ModelEntity?
                if let grabbedModel = self.grabbedObject {
                    targetModel = grabbedModel
                } else {
                    targetModel = self.lastPlacedObject
                }
                
                if let model = targetModel {
                    self.updateObjectColor(on: model, isPinching: isPinching)
                }
            }
            .store(in: &cancellables)
            
        viewModel.placeObjectSubject
            .sink { [weak self] in
                self?.placeObjectAtCenter()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - ARCoachingOverlayViewDelegate
    
    func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView) {
        viewModel.isCoachingActive = true
    }
    
    func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) {
        viewModel.isCoachingActive = false
    }

    // MARK: - Object Placement
    
    private func placeObjectAtCenter() {
        let viewCenter = self.center
        // Use .existingPlaneInfinite for reliable hits even at the edges of detected planes
        guard let raycastResult = self.raycast(from: viewCenter, allowing: .existingPlaneInfinite, alignment: .any).first else {
            print("Center-screen raycast did not hit any surface.")
            return
        }
        Task { await placeObject(of: viewModel.selectedModelType, at: raycastResult.worldTransform) }
    }
    
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let tapLocation = recognizer.location(in: self)
        guard let raycastResult = self.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .any).first else {
            print("Tap raycast did not hit any surface.")
            return
        }
        Task { await placeObject(of: viewModel.selectedModelType, at: raycastResult.worldTransform) }
    }
    
    @MainActor
    private func placeObject(of type: ModelType, at worldTransform: simd_float4x4) async {
        let newObject: ModelEntity
        
        do {
            switch type {
            case .cube:
                newObject = ModelEntity(mesh: .generateBox(size: 0.1, cornerRadius: 0.005), materials: [SimpleMaterial(color: .gray, roughness: 0.15, isMetallic: true)])
            case .sphere:
                newObject = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [SimpleMaterial(color: .gray, roughness: 0.15, isMetallic: true)])
            case .cylinder:
                newObject = ModelEntity(mesh: .generateCylinder(height: 0.1, radius: 0.05), materials: [SimpleMaterial(color: .gray, roughness: 0.15, isMetallic: true)])
            case .custom:
                // Correctly load the model using RealityKit's asynchronous loading API
                newObject = try await Entity(named: "toy_biplane_realistic.usdz") as! ModelEntity
            }
            
            // --- Make the object grabbable and give it physics ---
            newObject.generateCollisionShapes(recursive: true)
            newObject.components.set(GrabbableComponent())
            
            if let model = newObject.model {
                let material = PhysicsMaterialResource.generate(staticFriction: 0.8, dynamicFriction: 0.8, restitution: 0.2)
                let body = try await PhysicsBodyComponent(
                    shapes: [try await .generateConvex(from: model.mesh)],
                    mass: 1.0,
                    material: material,
                    mode: .dynamic
                )
                newObject.components.set(body)
            }
            // ---
            
            let anchor = AnchorEntity(world: worldTransform)
            anchor.addChild(newObject)
            self.scene.addAnchor(anchor)
            
            self.lastPlacedObject = newObject
            updateObjectColor(on: newObject, isPinching: viewModel.isPinching)

        } catch {
            print("Failed to load model for type \(type): \(error)")
        }
    }
    
    private func updateObjectColor(on object: ModelEntity, isPinching: Bool) {
        if var material = object.model?.materials.first as? SimpleMaterial {
            material.color.tint = isPinching ? .green : .gray
            object.model?.materials[0] = material
        }
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Throttle the frame processing to avoid overload.
        guard !isProcessingFrame else {
            return
        }
        isProcessingFrame = true
        
        // Create a CGImage from the frame's CVPixelBuffer.
        // This copies the pixel data and releases the ARFrame's buffer,
        // preventing the "retaining ARFrames" warning.
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            print("Failed to create CGImage from frame.")
            self.isProcessingFrame = false
            return
        }
        
        // Perform the Vision request on a background thread.
        DispatchQueue.global(qos: .userInitiated).async {
            // Use a defer block to guarantee the flag is reset on the main thread.
            defer {
                DispatchQueue.main.async {
                    self.isProcessingFrame = false
                }
            }
            
            // The handler now uses the independent CGImage.
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .right, options: [:])
            
            do {
                try handler.perform([self.handPoseRequest])
                
                if let observation = self.handPoseRequest.results?.first {
                    DispatchQueue.main.async {
                        self.viewModel.handDetected = true
                        self.processHand(observation: observation)
                    }
                } else {
                    DispatchQueue.main.async {
                        self.viewModel.handDetected = false
                        self.viewModel.isPinching = false
                        self.hideAllJoints()
                    }
                }
            } catch {
                print("Failed to perform Vision request: \(error)")
            }
        }
    }
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let planeAnchor = anchor as? ARPlaneAnchor else { continue }
            addOrUpdatePlaneCollision(for: planeAnchor)
        }
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let planeAnchor = anchor as? ARPlaneAnchor else { continue }
            addOrUpdatePlaneCollision(for: planeAnchor)
        }
    }
    
    /// Creates or updates an invisible collision plane entity matching the detected ARPlaneAnchor.
    /// This gives dynamic physics objects (cubes, spheres, etc.) a surface to land on.
    private func addOrUpdatePlaneCollision(for planeAnchor: ARPlaneAnchor) {
        let extent = planeAnchor.extent
        let width = CGFloat(extent.x)
        let depth = CGFloat(extent.z)
        
        if let existingAnchor = planeEntities[planeAnchor.identifier] {
            // Update the existing collision plane to match the refined plane size
            if let planeEntity = existingAnchor.children.first as? ModelEntity {
                planeEntity.model?.mesh = .generatePlane(width: Float(width), depth: Float(depth))
                planeEntity.collision = nil
                planeEntity.generateCollisionShapes(recursive: false)
                planeEntity.position = SIMD3<Float>(planeAnchor.center.x, 0, planeAnchor.center.z)
            }
        } else {
            // Create a new invisible collision plane
            let planeMesh = MeshResource.generatePlane(width: Float(width), depth: Float(depth))
            let material = OcclusionMaterial() // Invisible but blocks rendering behind it
            let planeEntity = ModelEntity(mesh: planeMesh, materials: [material])
            planeEntity.position = SIMD3<Float>(planeAnchor.center.x, 0, planeAnchor.center.z)
            planeEntity.generateCollisionShapes(recursive: false)
            planeEntity.physicsBody = PhysicsBodyComponent(mode: .static)
            
            let anchorEntity = AnchorEntity(anchor: planeAnchor)
            anchorEntity.addChild(planeEntity)
            self.scene.addAnchor(anchorEntity)
            planeEntities[planeAnchor.identifier] = anchorEntity
        }
    }
    
    // MARK: - Hand Tracking and Gesture Logic
    
    /// Tracks whether we were pinching on the previous frame, so we can detect transitions.
    private var wasPinching = false
    
    /// The distance from the camera to the grabbed object at the moment of grab.
    /// This keeps the object at a consistent depth while dragging.
    private var grabDistance: Float?
    
    /// Screen-space offset (in points) between the hand and the object's projection.
    /// This prevents the object from snapping to the hand center when grabbed.
    private var grabScreenOffset: CGPoint?
    
    private func processHand(observation: VNHumanHandPoseObservation) {
        self.latestHandObservation = observation
        
        let currentlyPinching = detectPinch(in: observation)
        viewModel.isPinching = currentlyPinching
        
        guard let handScreenPoint = getHandScreenPoint(observation: observation) else {
            wasPinching = currentlyPinching
            return
        }
        
        // --- Pinch started this frame: try to grab an object ---
        if currentlyPinching && !wasPinching {
            tryGrabObject(handScreenPoint: handScreenPoint)
        }
        
        // --- Currently holding an object: move it to follow the hand ---
        if let grabbedObject = self.grabbedObject,
           let grabDistance = self.grabDistance,
           let grabScreenOffset = self.grabScreenOffset {
            
            if currentlyPinching {
                // Compute the target screen point (hand + offset so object doesn't snap)
                let targetScreenPoint = CGPoint(
                    x: handScreenPoint.x + grabScreenOffset.x,
                    y: handScreenPoint.y + grabScreenOffset.y
                )
                
                // Cast a ray from camera through that screen point, place object at stored depth
                if let ray = self.ray(through: targetScreenPoint) {
                    let newPosition = ray.origin + ray.direction * grabDistance
                    grabbedObject.setPosition(newPosition, relativeTo: nil)
                }
            } else {
                // Pinch ended: release the object and let physics take over
                releaseGrabbedObject()
            }
        }
        
        wasPinching = currentlyPinching
    }
    
    /// Attempts to grab the closest grabbable entity near the hand's screen position.
    private func tryGrabObject(handScreenPoint: CGPoint) {
        guard grabbedObject == nil else { return }
        
        var closestMatch: (anchor: AnchorEntity, entity: ModelEntity, distance: CGFloat, projected: CGPoint)? = nil

        for anchor in self.scene.anchors {
            guard let anchorEntity = anchor as? AnchorEntity else { continue }
            for child in anchor.children {
                guard let entity = child as? ModelEntity,
                      entity.components.has(GrabbableComponent.self) else { continue }
                
                let worldPos = entity.position(relativeTo: nil)
                guard let projected = self.project(worldPos) else { continue }
                
                let dx = handScreenPoint.x - projected.x
                let dy = handScreenPoint.y - projected.y
                let screenDist = sqrt(dx * dx + dy * dy)
                
                // Screen-space threshold — hand must appear over or near the object
                if screenDist < 120 {
                    if closestMatch == nil || screenDist < closestMatch!.distance {
                        closestMatch = (anchorEntity, entity, screenDist, projected)
                    }
                }
            }
        }
        
        guard let target = closestMatch else {
            print("No grabbable object near hand (screen pos: \(handScreenPoint))")
            return
        }
        
        print("Grabbed object at screen distance: \(target.distance)")
        
        // Store the screen-space offset between the hand and the object's projection
        // so the object doesn't snap to the hand center
        self.grabScreenOffset = CGPoint(
            x: target.projected.x - handScreenPoint.x,
            y: target.projected.y - handScreenPoint.y
        )
        
        // Switch to kinematic FIRST so physics doesn't fight us while dragging
        target.entity.physicsBody?.mode = .kinematic
        
        let entityWorldPos = target.entity.position(relativeTo: nil)
        
        // Now compute grab distance from the entity's actual position
        let cameraPos = self.cameraTransform.translation
        self.grabDistance = simd_distance(cameraPos, entityWorldPos)

        self.grabbedObject = target.entity
        
        // Update color to show it's grabbed
        updateObjectColor(on: target.entity, isPinching: true)
    }
    
    /// Releases the currently grabbed object and lets physics resume.
    private func releaseGrabbedObject() {
        if let grabbedModel = grabbedObject {
            grabbedModel.physicsBody?.mode = .dynamic
            updateObjectColor(on: grabbedModel, isPinching: false)
            self.lastPlacedObject = grabbedModel
        }
        grabbedObject = nil
        grabDistance = nil
        grabScreenOffset = nil
    }
    
    /// Returns true if the thumb tip and index tip are close enough to count as a pinch.
    private func detectPinch(in observation: VNHumanHandPoseObservation) -> Bool {
        guard let thumbTip = try? observation.recognizedPoint(.thumbTip),
              let indexTip = try? observation.recognizedPoint(.indexTip),
              thumbTip.confidence > 0.5, indexTip.confidence > 0.5 else {
            return false
        }
        let distance = thumbTip.location.distance(to: indexTip.location)
        return distance < 0.05
    }
    
    /// Returns the hand's screen-space position (the midpoint between thumb tip and index tip).
    private func getHandScreenPoint(observation: VNHumanHandPoseObservation) -> CGPoint? {
        guard let thumbTip = try? observation.recognizedPoint(.thumbTip),
              let indexTip = try? observation.recognizedPoint(.indexTip),
              thumbTip.confidence > 0.3, indexTip.confidence > 0.3 else {
            return nil
        }
        
        let midpoint = CGPoint(x: (thumbTip.location.x + indexTip.location.x) / 2,
                               y: (thumbTip.location.y + indexTip.location.y) / 2)
        
        let viewSize = self.bounds.size
        
        // Vision coordinate origin is bottom-left.
        // Since we process the image with .right orientation, Vision output is upright.
        // We just need to flip the Y axis for UIKit.
        return CGPoint(x: midpoint.x * viewSize.width,
                       y: (1 - midpoint.y) * viewSize.height)
    }
    


    private func updateJoint(jointName: VNHumanHandPoseObservation.JointName, at location: CGPoint) {
        let viewSize = self.bounds.size
        let screenLocation = CGPoint(x: location.y * viewSize.width, y: (1 - location.x) * viewSize.height)

        if let raycastResult = self.raycast(from: screenLocation, allowing: .estimatedPlane, alignment: .any).first {
            let jointEntity: ModelEntity
            
            if let existingEntity = jointEntities[jointName] {
                jointEntity = existingEntity
            } else {
                let newEntity = ModelEntity(mesh: .generateSphere(radius: 0.005), materials: [SimpleMaterial(color: .cyan, isMetallic: false)])
                handAnchor.addChild(newEntity)
                jointEntities[jointName] = newEntity
                jointEntity = newEntity
            }
            jointEntity.isEnabled = true
            jointEntity.transform = Transform(matrix: raycastResult.worldTransform)
        }
    }
    
    private func hideAllJoints() {
        for (_, entity) in jointEntities {
            entity.isEnabled = false
        }
    }

}

// MARK: - Helpers

extension CGPoint {
    func distance(to point: CGPoint) -> CGFloat {
        return sqrt(pow(x - point.x, 2) + pow(y - point.y, 2))
    }
}

#Preview {
    ContentView()
}
