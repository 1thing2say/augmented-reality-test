//
//  ContentView.swift
//  augmented reality test
//
//  Created by my computer on 6/2/26.
//

import SwiftUI
import RealityKit
import ARKit
import Vision // We need to import the Vision framework for hand tracking

/// The main SwiftUI view. It will host our AR experience.
struct ContentView : View {
    var body: some View {
        // We use a UIViewRepresentable to wrap our custom ARView.
        ARViewContainer().edgesIgnoringSafeArea(.all)
    }
}

/// A UIViewRepresentable to bridge UIKit's ARView into a SwiftUI view.
struct ARViewContainer: UIViewRepresentable {
    
    func makeUIView(context: Context) -> CustomARView {
        // Create our custom AR view and return it.
        return CustomARView(frame: .zero)
    }
    
    func updateUIView(_ uiView: CustomARView, context: Context) {}
    
}

/// This is our custom ARView class. It handles the AR session,
/// sets up the scene, and processes camera frames for hand tracking.
class CustomARView: ARView, ARSessionDelegate {
    
    // A dictionary to hold the small spheres that visualize the hand joints.
    private var jointEntities: [VNHumanHandPoseObservation.JointName: ModelEntity] = [:]
    
    // An anchor for all the joint entities.
    private let handAnchor = AnchorEntity()
    
    // A reference to the cube, so we can change its color.
    private var cubeEntity: ModelEntity!

    // The main Vision request for detecting hand poses.
    private let handPoseRequest = VNDetectHumanHandPoseRequest()

    required init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        
        // 1. Set this view as the session's delegate.
        // This allows us to receive AR a camera frame for each update.
        session.delegate = self
        
        // 2. Set up the AR session for world tracking.
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        session.run(config)
        
        // 3. Add the initial scene content.
        setupScene()
    }
    
    @MainActor required dynamic init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupScene() {
        // Add the anchor for hand joint visualizations to the scene.
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
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Get the current camera image as a CVPixelBuffer.
        let pixelBuffer = frame.capturedImage
        
        // Create a Vision image request handler for the current frame.
        // We use .right orientation because AR apps are typically in landscape right.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        
        // The Vision request is computationally expensive, so we run it on a background thread.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Perform the hand pose request.
                try handler.perform([self.handPoseRequest])
                
                // If a hand is detected, get the first observation.
                if let observation = self.handPoseRequest.results?.first {
                    // Dispatch back to the main thread to update the AR scene.
                    DispatchQueue.main.async {
                        self.processHand(observation: observation)
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
            // Get all the recognized points for the hand.
            let recognizedPoints = try observation.recognizedPoints(.all)
            
            // Visualize each joint with a sphere.
            for (jointName, point) in recognizedPoints where point.confidence > 0.3 {
                updateJoint(jointName: jointName, at: point.location)
            }
            
            // Check for a pinch gesture.
            checkForPinch(in: observation)
            
        } catch {
            print("Error processing hand observation: \(error)")
        }
    }
    
    private func updateJoint(jointName: VNHumanHandPoseObservation.JointName, at location: CGPoint) {
        // Use a raycast from the 2D screen point to find a 3D position in the scene.
        if let raycastResult = self.raycast(from: location, allowing: .estimatedPlane, alignment: .any).first {
            let jointEntity: ModelEntity
            
            // If we already have an entity for this joint, use it.
            if let existingEntity = jointEntities[jointName] {
                jointEntity = existingEntity
            } else {
                // Otherwise, create a new small sphere entity.
                let newEntity = ModelEntity(mesh: .generateSphere(radius: 0.005), materials: [SimpleMaterial(color: .cyan, isMetallic: false)])
                handAnchor.addChild(newEntity) // Add it to our hand anchor.
                jointEntities[jointName] = newEntity // Store it for future updates.
                jointEntity = newEntity
            }
            
            // Update the entity's transform to the new 3D position.
            jointEntity.transform = Transform(matrix: raycastResult.worldTransform)
        }
    }
    
    private func checkForPinch(in observation: VNHumanHandPoseObservation) {
        var isPinching = false
        defer {
            // `SimpleMaterial` is a struct (a value type). To modify a property,
            // you must get a mutable copy, change it, and then assign the copy
            // back to the entity's materials collection.
            if var material = self.cubeEntity.model?.materials[0] as? SimpleMaterial {
                material.color = .init(tint: isPinching ? UIColor.green : UIColor.gray)
                self.cubeEntity.model?.materials[0] = material
            }
        }

        do {
            // Get the points for the thumb and index finger tips.
            let thumbTip = try observation.recognizedPoint(.thumbTip)
            let indexTip = try observation.recognizedPoint(.indexTip)

            // Only proceed if the tips are detected with high confidence.
            guard thumbTip.confidence > 0.5, indexTip.confidence > 0.5 else {
                return
            }

            // Calculate the distance between the tips in 2D screen space.
            let distance = thumbTip.location.distance(to: indexTip.location)

            // If the distance is very small, we consider it a pinch.
            if distance < 0.05 {
                isPinching = true
            }
        } catch {
            // It's normal for a joint to not be detected sometimes, so we can ignore this error.
            // isPinching will remain false, and the defer block will reset the color.
        }
    }
}

// A helper extension for calculating the distance between two CGPoints.
extension CGPoint {
    func distance(to point: CGPoint) -> CGFloat {
        return sqrt(pow(x - point.x, 2) + pow(y - point.y, 2))
    }
}

#Preview {
    ContentView()
}
