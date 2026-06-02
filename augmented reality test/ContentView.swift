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

// MARK: - ViewModel
/// An object to communicate state from the ARView to the SwiftUI HUD.
class ARViewModel: ObservableObject {
    @Published var handDetected: Bool = false
    @Published var isPinching: Bool = false
}


// MARK: - SwiftUI Views

/// The main SwiftUI view. It will host our AR experience and the HUD.
struct ContentView : View {
    // Create a state object for our ViewModel.
    @StateObject private var viewModel = ARViewModel()
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // The AR View that renders the scene.
            ARViewContainer(viewModel: viewModel)
                .edgesIgnoringSafeArea(.all)
            
            // The HUD view, overlaid on top.
            HUDView(viewModel: viewModel)
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
        .padding()
        .background(Color.black.opacity(0.5))
        .cornerRadius(10)
        .padding() // Add padding to position it from the edge of the screen
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
    
    // A reference to the cube, so we can change its color.
    private var cubeEntity: ModelEntity!

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
        
        // 3. Add the initial scene content and subscribers.
        setupScene()
        subscribeToViewModel()
    }
    
    @MainActor required dynamic init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // ARView subclasses require this initializer.
    // The 'override' keyword is removed to resolve the warning, as it's implied for required initializers.
    // One of the duplicate declarations was also removed.
    @MainActor @preconcurrency required dynamic init(frame frameRect: CGRect) {
        fatalError("init(frame:) has not been implemented")
    }
    
    private func setupScene() {
        // Add the anchor for the hand joints to the scene.
        self.scene.addAnchor(handAnchor)

        // Create the cube model you had before.
        cubeEntity = ModelEntity(
            mesh: .generateBox(size: 0.1, cornerRadius: 0.005),
            materials: [SimpleMaterial(color: .gray, roughness: 0.15, isMetallic: true)]
        )
        
        // Create an anchor for the cube and add it to the scene.
        let anchor = AnchorEntity(.plane(.horizontal, classification: .any, minimumBounds: SIMD2<Float>(0.2, 0.2)))
        anchor.addChild(cubeEntity)
        self.scene.addAnchor(anchor)
    }
    
    /// Subscribes to changes in the ViewModel to update the AR scene.
    private func subscribeToViewModel() {
        // Listen for changes to the `isPinching` property.
        viewModel.$isPinching
            .receive(on: RunLoop.main) // Ensure UI updates happen on the main thread
            .sink { [weak self] isPinching in
                guard let self = self, var material = self.cubeEntity.model?.materials[0] as? SimpleMaterial else { return }
                // Change the cube color based on the pinch state.
                material.color.tint = isPinching ? .green : .gray
                self.cubeEntity.model?.materials[0] = material
            }
            .store(in: &cancellables)
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
