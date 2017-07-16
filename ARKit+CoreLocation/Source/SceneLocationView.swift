//
//  SceneLocationView.swift
//  ARKit+CoreLocation
//
//  Created by Andrew Hart on 02/07/2017.
//  Copyright © 2017 Project Dent. All rights reserved.
//

import Foundation
import ARKit
import CoreLocation
import CocoaLumberjack
import MapKit

class SceneLocationView: UIView, ARSCNViewDelegate, LocationManagerDelegate {
protocol SceneLocationViewDelegate: class {
    func sceneLocationViewDidAddSceneLocationEstimate(sceneLocationView: SceneLocationView, position: SCNVector3, location: CLLocation)
    func sceneLocationViewDidRemoveSceneLocationEstimate(sceneLocationView: SceneLocationView, position: SCNVector3, location: CLLocation)
}

    ///The limit to the scene, in terms of what data is considered reasonably accurate.
    ///Measured in meters.
    private static let sceneLimit = 100.0
    
    private let sceneView = ARSCNView()
    
    weak var delegate: SceneLocationViewDelegate?
    
    let locationManager = LocationManager()
    
    private(set) var locationNodes = [LocationNode]()
    
    private var sceneLocationEstimates = [SceneLocationEstimate]()
    
    private var sceneNode: SCNNode? {
        didSet {
            if sceneNode != nil {
                for locationNode in locationNodes {
                    sceneNode!.addChildNode(locationNode)
                }
            }
        }
    }
    
    private var updateEstimatesTimer: Timer?
    
    private var didFetchInitialLocation = false
    
    //MARK: Setup
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        locationManager.delegate = self
        
        sceneView.delegate = self
        
        // Show statistics such as fps and timing information
        sceneView.showsStatistics = false
        
        sceneView.debugOptions = [ARSCNDebugOptions.showFeaturePoints]
        
        // Create a new scene
        let scene = SCNScene(named: "art.scnassets/scene.scn")!
        sceneView.scene = scene
        addSubview(sceneView)
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        sceneView.frame = self.bounds
    }
    
    func run() {
        DDLogDebug("run")
        // Create a session configuration
        let configuration = ARWorldTrackingSessionConfiguration()
        configuration.planeDetection = .horizontal
        configuration.worldAlignment = .gravityAndHeading
        
        // Run the view's session
        sceneView.session.run(configuration)
        
        updateEstimatesTimer?.invalidate()
        updateEstimatesTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(SceneLocationView.updateLocationData), userInfo: nil, repeats: true)
    }
    
    func pause() {
        sceneView.session.pause()
        updateEstimatesTimer?.invalidate()
        updateEstimatesTimer = nil
    }
    
    @objc func updateLocationData() {
        removeOldLocationEstimates()
        confirmLocationOfDistantLocationNodes()
        updatePositionOfLocationNodesWithConfirmedLocation()
    }
    
    }
    
    //MARK: Scene location estimates
    
    func currentScenePosition() -> SCNVector3? {
        guard let pointOfView = sceneView.pointOfView else {
            return nil
        }
        
        return sceneView.scene.rootNode.convertPosition(pointOfView.position, to: sceneNode)
    }
    
    ///Adds a scene location estimate based on current time, camera position and location from location manager
    func addSceneLocationEstimate(location: CLLocation) {
        if let position = currentScenePosition() {
            self.addSceneLocationEstimate(location: location, currentPosition: position)
        }
    }
    
    func addSceneLocationEstimate(location: CLLocation, currentPosition: SCNVector3) {
        let sceneLocationEstimate = SceneLocationEstimate(location: location, position: currentPosition)
        self.sceneLocationEstimates.append(sceneLocationEstimate)
        
        delegate?.sceneLocationViewDidAddSceneLocationEstimate(sceneLocationView: self, position: currentPosition, location: location)
    }
    
    func removeOldLocationEstimates() {
        if let currentScenePosition = currentScenePosition() {
            self.removeOldLocationEstimates(currentScenePosition: currentScenePosition)
        }
    }
    
    func removeOldLocationEstimates(currentScenePosition: SCNVector3) {
        let currentPoint = CGPoint.pointWithVector(vector: currentScenePosition)
        
        sceneLocationEstimates = sceneLocationEstimates.filter({
            let point = CGPoint.pointWithVector(vector: $0.position)
            
            let radiusContainsPoint = currentPoint.radiusContainsPoint(radius: CGFloat(SceneLocationView.sceneLimit), point: point)
            
            if !radiusContainsPoint {
                delegate?.sceneLocationViewDidRemoveSceneLocationEstimate(sceneLocationView: self, position: $0.position, location: $0.location)
            }
            
            return radiusContainsPoint
        })
    }
    
    ///The best estimation of location that has been taken
    ///This takes into account horizontal accuracy, and the time at which the estimation was taken
    ///favouring the most accurate, and then the most recent result.
    ///This doesn't indicate where the user currently is.
    func bestLocationEstimate() -> SceneLocationEstimate? {
        let sortedLocationEstimates = sceneLocationEstimates.sorted(by: {
            if $0.location.horizontalAccuracy == $1.location.horizontalAccuracy {
                return $0.location.timestamp > $1.location.timestamp
            }
            
            return $0.location.horizontalAccuracy < $1.location.horizontalAccuracy
        })
        
        return sortedLocationEstimates.first
    }
    
    func currentLocation() -> CLLocation? {
        guard let bestEstimate = self.bestLocationEstimate(),
            let position = currentScenePosition() else {
                return nil
        }
        
        return bestEstimate.translatedLocation(to: position)
    }
    
    //MARK: LocationNodes
    
    ///Upon being added, a node's location, locationConfirmed and position will be modified and should not be changed externally.
    func addLocationNodeForCurrentPosition(locationNode: LocationNode) {
        guard let currentPosition = currentScenePosition(),
        let currentLocation = currentLocation(),
        let sceneNode = self.sceneNode else {
            return
        }
        
        locationNode.location = currentLocation
        locationNode.locationConfirmed = false
        locationNode.position = currentPosition
        
        locationNodes.append(locationNode)
        sceneNode.addChildNode(locationNode)
    }
    
    ///location not being nil, and locationConfirmed being true are required
    ///Upon being added, a node's position will be modified and should not be changed externally.
    ///location will not be modified, but taken as accurate.
    func addLocationNodeWithConfirmedLocation(locationNode: LocationNode) {
        if locationNode.location == nil || locationNode.locationConfirmed == false {
            return
        }
        
        updatePositionOfLocationNode(locationNode: locationNode)
        
        locationNodes.append(locationNode)
        sceneNode?.addChildNode(locationNode)
    }
    
    func confirmLocationOfDistantLocationNodes() {
        guard let currentPosition = currentScenePosition() else {
            return
        }
        
        for locationNode in locationNodes {
            if !locationNode.locationConfirmed {
                let currentPoint = CGPoint.pointWithVector(vector: currentPosition)
                let locationNodePoint = CGPoint.pointWithVector(vector: locationNode.position)
                
                if !currentPoint.radiusContainsPoint(radius: CGFloat(SceneLocationView.sceneLimit), point: locationNodePoint) {
                    confirmLocationOfLocationNode(locationNode: locationNode)
                }
            }
        }
    }
    
    func confirmLocationOfLocationNode(locationNode: LocationNode) {
        if let bestLocationEstimate = bestLocationEstimate(),
            locationNode.location == nil ||
            bestLocationEstimate.location.horizontalAccuracy < locationNode.location!.horizontalAccuracy {
            let locationTranslation = LocationTranslation(
                latitudeTranslation: Double(locationNode.position.z - bestLocationEstimate.position.z),
                longitudeTranslation: Double(locationNode.position.x - bestLocationEstimate.position.x))
            
            let translatedLocation = bestLocationEstimate.location.translatedLocation(with: locationTranslation)
            
            locationNode.location = translatedLocation
            locationNode.locationConfirmed = true
        }
    }
    
    func updatePositionOfLocationNodesWithConfirmedLocation() {
        for locationNode in locationNodes {
            if locationNode.locationConfirmed {
                updatePositionOfLocationNode(locationNode: locationNode)
            }
        }
    }
    
    func updatePositionOfLocationNode(locationNode: LocationNode) {
        guard let currentPosition = currentScenePosition(),
            let currentLocation = currentLocation() else {
            return
        }
        
        //Position is set to a position coordinated via the current position
        let locationTranslation = currentLocation.translation(toLocation: locationNode.location!)
        
        let position = SCNVector3(
            x: currentPosition.x + Float(locationTranslation.longitudeTranslation),
            y: currentPosition.y,
            z: currentPosition.z - Float(locationTranslation.longitudeTranslation))
        
        locationNode.position = position
    }
    
    //MARK: ARSCNViewDelegate
    
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        if sceneNode == nil {
            sceneNode = SCNNode()
            sceneView.scene.rootNode.addChildNode(sceneNode!)
            
            let axesNode = SCNNode.axesNode(quiverLength: 0.1, quiverThickness: 0.5)
            sceneNode?.addChildNode(axesNode)
        }
        
        if !didFetchInitialLocation {
            //Current frame and current location are required for this to be successful
            if sceneView.session.currentFrame != nil,
                let currentLocation = self.locationManager.currentLocation {
                didFetchInitialLocation = true
                
                self.addSceneLocationEstimate(location: currentLocation)
            }
        }
    }
    
    //MARK: LocationManager
    
    func locationManagerDidUpdateLocation(_ locationManager: LocationManager, location: CLLocation) {
        self.addSceneLocationEstimate(location: location)
    }
    
    func locationManagerDidUpdateHeading(_ locationManager: LocationManager, heading: CLLocationDirection, accuracy: CLLocationAccuracy) {
    }
}
