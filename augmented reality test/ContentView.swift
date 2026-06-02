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

// MARK: - Model Definitions

/// An enum to represent the different types of models the user can place.
enum ModelType: String, CaseIterable, Identifiable {
    case cube = "Cube"
    case sphere = "Sphere"
    case custom = "Custom Model"
    
    var id: String { self.rawValue }
}


// MARK: - ViewModel

/// An object to communicate state from the ARView to the SwiftUI HUD.
class ARViewModel: ObservableObject {
    @Published var handDetected: Bool = false
    @Published var isPinching: Bool = false
    @Published var selectedModelType: ModelType = .cube
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
            
            // A VStack to layer the HUD on top and the picker on the bottom.
            VStack {
                HUDView(viewModel: viewModel)
                Spacer()
                ModelPickerView(viewModel: viewModel)
                    .padding(.bottom, 30) // Add padding from the bottom edge
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
class CustomARView: ARView, ARSessionDelegate {
    
    private let viewModel: ARViewModel
    private var cancellables: Set<AnyCancellable> = []
    
    // A dictionary to hold the small spheres that visualize the hand joints.
    private var jointEntities: [VNHumanHandPoseObservation.JointName: ModelEntity] = [:]
    
    // A single anchor for all hand-related entities.
    private let handAnchor = AnchorEntity()
    
    // A reference to the last placed model, so we can change its color.
    private var lastPlacedObject: ModelEntity?

    // The main Vision request for detecting hand poses.
    private let handPoseRequest = VNDetectHumanHandPoseRequest()

    init(frame frameRect: CGRect, viewModel: ARViewModel) {
        self.viewModel = viewModel
        super.init(frame: frameRect)
        
        // 1. Set this view as the session's delegate.
        session.delegate = self
        
        // 2. Set up the AR session for world tracking.
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        session.run(config)
        
        // 3. Add the initial scene content, gestures, and subscribers.
        setupScene()
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
        // Add the anchor for the hand joints to the scene.
        self.scene.addAnchor(handAnchor)
    }
    
    /// Adds a tap gesture recognizer to the view for placing objects.
    private func setupGestures() {
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        self.addGestureRecognizer(tapRecognizer)
    }
    
    /// Subscribes to changes in the ViewModel to update the AR scene.
    private func subscribeToViewModel() {
        // Listen for changes to the `isPinching` property.
        viewModel.$isPinching
            .receive(on: RunLoop.main) // Ensure UI updates happen on the main thread
            .sink { [weak self] isPinching in
                self?.updateObjectColor(isPinching: isPinching)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Object Placement
    
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let tapLocation = recognizer.location(in: self)

        // Raycast from the tap location to find a 3D point on a real-world surface.
        guard let raycastResult = self.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .any).first else {
            print("Tap raycast did not hit any surface.")
            return
        }

        // Use a Task to handle the potentially asynchronous model loading.
        Task {
            await placeObject(of: viewModel.selectedModelType, at: raycastResult.worldTransform)
        }
    }
    
    @MainActor
    private func placeObject(of type: ModelType, at worldTransform: simd_float4x4) async {
        let newObject: ModelEntity
        
        do {
            switch type {
            case .cube:
                newObject = ModelEntity(
                    mesh: .generateBox(size: 0.1, cornerRadius: 0.005),
                    materials: [SimpleMaterial(color: .gray, roughness: 0.15, isMetallic: true)]
                )
            case .sphere:
                newObject = ModelEntity(
                    mesh: .generateSphere(radius: 0.05),
                    materials: [SimpleMaterial(color: .gray, roughness: 0.15, isMetallic: true)]
                )
            case .custom:
                // IMPORTANT: Replace "MyModel.usdz" with your model file name.
                newObject = try await ModelEntity.loadModel(named: "toy_biplane_realistic.usdz")
            }
            
            // Place the object in the scene.
            let anchor = AnchorEntity(world: worldTransform)
            anchor.addChild(newObject)
            self.scene.addAnchor(anchor)
            
            // Keep a reference to the last placed object.
            self.lastPlacedObject = newObject
            
            // Set the initial color based on the current pinch state.
            updateObjectColor(isPinching: viewModel.isPinching)

        } catch {
            print("Failed to load model for type \(type): \(error)")
        }
    }
    
    /// A helper function to change the model's color based on the pinch state.
    private func updateObjectColor(isPinching: Bool) {
        guard let object = self.lastPlacedObject else { return }
        
        // Create a new material to update the model's color.
        if var material = object.model?.materials.first as? SimpleMaterial {
            material.color.tint = isPinching ? .green : .gray
            object.model?.materials[0] = material
        }
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([self.handPoseRequest])
                
                if let observation = self.handPoseRequest.results?.first {
                    DispatchQueue.main.async {
                        self.viewModel.handDetected = true
                        self.processHand(observation: observation)
                    }
                } else {
                    // No hand was detected in the frame.
                    DispatchQueue.main.async {
                        self.viewModel.handDetected = false
                        self.viewModel.isPinching = false // Ensure pinch is reset
                        self.hideAllJoints()
                    }
                }
            } catch {
                print("Failed to perform Vision request: \(error)")
            }
        }
    }
    
    // MARK: - Hand Tracking and Gesture Logic
    
    private func processHand(observation: VNHumanHandPoseObservation) {
        do {
            let recognizedPoints = try observation.recognizedPoints(.all)
            
            for (jointName, point) in recognizedPoints where point.confidence > 0.3 {
                updateJoint(jointName: jointName, at: point.location)
            }
            
            checkForPinch(in: observation)
            
        } catch {
            print("Error processing hand observation: \(error)")
        }
    }
    
    private func updateJoint(jointName: VNHumanHandPoseObservation.JointName, at location: CGPoint) {
        if let raycastResult = self.raycast(from: location, allowing: .estimatedPlane, alignment: .any).first {
            let jointEntity: ModelEntity
            
            if let existingEntity = jointEntities[jointName] {
                jointEntity = existingEntity
            } else {
                let newEntity = ModelEntity(mesh: .generateSphere(radius: 0.005), materials: [SimpleMaterial(color: .cyan, isMetallic: false)])
                // Add the new joint entity to our hand-specific anchor.
                handAnchor.addChild(newEntity)
                jointEntities[jointName] = newEntity
                jointEntity = newEntity
            }
            jointEntity.isEnabled = true
            jointEntity.transform = Transform(matrix: raycastResult.worldTransform)
        }
    }
    
    /// Hides all the joint spheres when the hand is not visible.
    private func hideAllJoints() {
        for (_, entity) in jointEntities {
            entity.isEnabled = false
        }
    }
    
    private func checkForPinch(in observation: VNHumanHandPoseObservation) {
        // Use a guard to safely get the points, if they can't be found, reset the pinch state.
        guard let thumbTip = try? observation.recognizedPoint(.thumbTip),
              let indexTip = try? observation.recognizedPoint(.indexTip),
              thumbTip.confidence > 0.5, indexTip.confidence > 0.5 else {
            viewModel.isPinching = false
            return
        }

        let distance = thumbTip.location.distance(to: indexTip.location)
        
        // Update the ViewModel based on the distance.
        viewModel.isPinching = distance < 0.05
    }
}

// MARK: - Helpers

// A helper extension for calculating the distance between two CGPoints.
extension CGPoint {
    func distance(to point: CGPoint) -> CGFloat {
        return sqrt(pow(x - point.x, 2) + pow(y - point.y, 2))
    }
}

#Preview {
    ContentView()
}
