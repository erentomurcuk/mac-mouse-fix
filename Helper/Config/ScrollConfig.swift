//
// --------------------------------------------------------------------------
// ScrollConfig.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2021
// Licensed under MIT
// --------------------------------------------------------------------------
//

import Cocoa
import CocoaLumberjackSwift

@objc class ScrollConfig: NSObject, NSCopying /*, NSCoding*/ {
    
    
    
    /// This class has almost all instance properties
    /// You can request the config once, then store it.
    /// You'll receive an independent instance that you can override with custom values. This should be useful for implementing Modifications in Scroll.m
    ///     Everything in ScrollConfigResult is lazy so that you only pay for what you actually use
    
    // MARK: Class functions
    
    @objc static var currentConfig = ScrollConfig() /// Singleton instance
    @objc static func deleteCache() { /// This should be called when the underlying config (which mirrors the config file) changes
        currentConfig = ScrollConfig() /// All the property values are cached in `currentConfig`, because the properties are lazy. Replacing with a fresh object deletes this implicit cache.
    }
    
    @objc static var linearCurve: Bezier = { () -> Bezier in
        
        typealias P = Bezier.Point
        let controlPoints: [P] = [P(x:0,y:0), P(x:0,y:0), P(x:1,y:1), P(x:1,y:1)]
        
        return Bezier(controlPoints: controlPoints, defaultEpsilon: 0.001) /// The default defaultEpsilon 0.08 makes the animations choppy
    }()
    
    @objc static var stringToEventFlagMask: NSDictionary = ["command" : CGEventFlags.maskCommand,
                                                            "control" : CGEventFlags.maskControl,
                                                            "option" : CGEventFlags.maskAlternate,
                                                            "shift" : CGEventFlags.maskShift]
    
    // MARK: Convenience functions
    ///     For accessing top level dict and different sub-dicts
    
    private var topLevel: NSDictionary {
        Config.configWithAppOverridesApplied()[kMFConfigKeyScroll] as! NSDictionary
    }
    private var other: NSDictionary {
        topLevel["other"] as! NSDictionary
    }
    private var smooth: NSDictionary {
        topLevel["smoothParameters"] as! NSDictionary
    }
    private var mod: NSDictionary {
        topLevel["modifierKeys"] as! NSDictionary
    }
    
    // MARK: General
    
    @objc lazy var smoothEnabled: Bool = true /* ScrollConfig.topLevel["smooth"] as! Bool */
    @objc lazy var disableAll: Bool = false /* topLevel["disableAll"] as! Bool */ /// This is currently unused. Could be used as a killswitch for all scrolling Interception
    
    // MARK: Invert Direction
    
    @objc func scrollInvert(event: CGEvent) -> MFScrollInversion {
        /// This can be used as a factor to invert things. kMFScrollInversionInverted is -1.
        
        if self.semanticScrollInvertUser == self.semanticScrollInvertSystem(event) {
            return kMFScrollInversionNonInverted
        } else {
            return kMFScrollInversionInverted
        }
    }
    lazy private var semanticScrollInvertUser: MFSemanticScrollInversion = kMFSemanticScrollInversionNormal /* MFSemanticScrollInversion(ScrollConfig.topLevel["naturalDirection"] as! UInt32) */
    private func semanticScrollInvertSystem(_ event: CGEvent) -> MFSemanticScrollInversion {
        
        /// Accessing userDefaults is actually surprisingly slow, so we're using NSEvent.isDirectionInvertedFromDevice instead... but NSEvent(cgEvent:) is slow as well...
        ///     .... So we're using our advanced knowledge of CGEventFields!!!
        
        
//            let isNatural = UserDefaults.standard.bool(forKey: "com.apple.swipescrolldirection") /// User defaults method
//            let isNatural = NSEvent(cgEvent: event)!.isDirectionInvertedFromDevice /// NSEvent method
        let isNatural = event.getIntegerValueField(CGEventField(rawValue: 137)!) != 0; /// CGEvent method
        
        return isNatural ? kMFSemanticScrollInversionNatural : kMFSemanticScrollInversionNormal
    }
    
    // MARK: Analysis
    
    @objc lazy var scrollSwipeThreshold_inTicks: Int = 2 /*other["scrollSwipeThreshold_inTicks"] as! Int;*/ /// If `scrollSwipeThreshold_inTicks` consecutive ticks occur, they are deemed a scroll-swipe.
    
    @objc lazy var fastScrollThreshold_inSwipes: Int = 4 /*other["fastScrollThreshold_inSwipes"] as! Int*/ /// On the `fastScrollThreshold_inSwipes`th consecutive swipe, fast scrolling kicks in
    
    @objc lazy var scrollSwipeMax_inTicks: Int = 9 /// Max number of ticks that we think can occur in a single swipe naturally (if the user isn't using a free-spinning scrollwheel). (See `consecutiveScrollSwipeCounter_ForFreeScrollWheel` definition for more info)
    
    @objc lazy var consecutiveScrollTickIntervalMax: TimeInterval = 160/1000
    /// ^ If more than `_consecutiveScrollTickIntervalMax` seconds passes between two scrollwheel ticks, then they aren't deemed consecutive.
    ///        other["consecutiveScrollTickIntervalMax"] as! Double;
    ///     msPerStep/1000 <- Good idea but we don't want this to depend on msPerStep
    
    @objc lazy var consecutiveScrollTickIntervalMin: TimeInterval = 15/1000
    /// ^ 15ms seemst to be smallest scrollTickInterval that you can naturally produce. But when performance drops, the scrollTickIntervals that we see can be much smaller sometimes.
    ///     This variable can be used to cap the observed scrollTickInterval to a reasonable value
    
    
    @objc lazy var consecutiveScrollSwipeMaxInterval: TimeInterval = 350/1000
    /// ^ If more than `_consecutiveScrollSwipeIntervalMax` seconds passes between two scrollwheel swipes, then they aren't deemed consecutive.
    ///        other["consecutiveScrollSwipeIntervalMax"] as! Double
    
    @objc lazy private var consecutiveScrollTickInterval_AccelerationEnd: TimeInterval = 15/1000
    /// ^ Used to define accelerationCurve. If the time interval between two ticks becomes less than `consecutiveScrollTickInterval_AccelerationEnd` seconds, then the accelerationCurve becomes managed by linear extension of the bezier instead of the bezier directly.
    
    @objc lazy var ticksPerSecond_DoubleExponentialSmoothing_InputValueWeight: Double = 0.5
    
    @objc lazy var ticksPerSecond_DoubleExponentialSmoothing_TrendWeight: Double = 0.2
    
    @objc lazy var ticksPerSecond_ExponentialSmoothing_InputValueWeight: Double = 0.5
    /// ^       1.0 -> Turns off smoothing. I like this the best
    ///     0.6 -> On larger swipes this counteracts acceleration and it's unsatisfying. Not sure if placebo
    ///     0.8 ->  Nice, light smoothing. Makes  scrolling slightly less direct. Not sure if placebo.
    ///     0.5 -> (Edit) I prefer smoother feel now in everything. 0.5 Makes short scroll swipes less accelerated which I like
    
    // MARK: Fast scroll
    
    @objc lazy var fastScrollExponentialBase = 1.35 /* other["fastScrollExponentialBase"] as! Double; */
    /// ^ How quickly fast scrolling gains speed.
    ///     Used to be 1.1 before scroll rework. Why so much higher now?
    
    
    @objc lazy var fastScrollFactor = 1.0 /*other["fastScrollFactor"] as! Double*/
    /// ^ With the introduction of fastScrollScale, this should always be 1.0
    
    @objc lazy var fastScrollScale = 0.3
    
    // MARK: Smooth scroll
    
    @objc var pxPerTickBase = 60 /* return smooth["pxPerStep"] as! Int */
    
    @objc lazy private var pxPerTickEnd: Int = 130
    
    @objc lazy var msPerStep = 140 /* smooth["msPerStep"] as! Int */
    
    @objc lazy var baseCurve: Bezier = { () -> Bezier in
        /// Base curve used to construct a Hybrid AnimationCurve in Scroll.m. This curve is applied before switching to a DragCurve to simulate physically accurate deceleration
        typealias P = Bezier.Point
        
        let controlPoints: [P] = [P(x:0,y:0), P(x:0,y:0), P(x:1,y:1), P(x:1,y:1)] /// Straight line
//        let controlPoints: [P] = [P(x:0,y:0), P(x:0,y:0), P(x:0.9,y:0), P(x:1,y:1)] /// Testing
//        let controlPoints: [P] = [P(x:0,y:0), P(x:0,y:0), P(x:0.5,y:0.9), P(x:1,y:1)]
        /// ^ Ease out but the end slope is not 0. That way. The curve is mostly controlled by the Bezier, but the DragCurve rounds things out.
        ///     Might be placebo but I really like how this feels
        
//        let controlPoints: [P] = [P(x:0,y:0), P(x:0,y:0), P(x:0.6,y:0.9), P(x:1,y:1)]
        /// ^ For use with low friction to cut the tails a little on long swipes. Turn up the msPerStep when using this
        
        return Bezier(controlPoints: controlPoints, defaultEpsilon: 0.001) /// The default defaultEpsilon 0.08 makes the animations choppy
    }()
    
    @objc lazy var stopSpeed = 50.0
    @objc lazy var dragExponent = 1.0 /* smooth["frictionDepth"] as! Double */
    @objc lazy var dragCoefficient = 23.0 /* smooth["friction"] as! Double */
    /// ^ Defines the Drag subcurve of the default Hybrid curve used for scrollwheel scrolling in Scroll.m. (When we're not sending momentumScrolls)
    
    @objc lazy var sendMomentumScrolls = true
    
    @objc let momentumStopSpeed = 50
    @objc let momentumDragExponent = 0.7
    @objc let momentumDragCoefficient = 40
    @objc let momentumMsPerStep = 205
    /// ^ Snappiest curve that can be used to send momentumScrolls.
    ///     If you make it snappier then it will cut off the build-in momentumScroll in apps like Xcode
    ///     Used in Scroll.m if sendMomentumScrolls == true
    
    @objc let trackpadStopSpeed = 1.0
    @objc let trackpadDragExponent = 0.7
    @objc let trackpadDragCoefficient = 30
    /// ^ Emulates the trackpad as closely as possible. Use in the default momentumScroll in GestureSimulator.m
    ///
    /// I just checked the formulas on Desmos, and I don't get how this can work with 0.8 as the exponent? (But it does??) If the value is `< 1.0` that gives a completely different curve that speeds up over time, instead of slowing down.
    
    // MARK: Acceleration
    
    @objc lazy var useAppleAcceleration = false
    /// ^ Ignore MMF acceleration algorithm and use values provided by macOS
    
    @objc lazy var accelerationHump = -0.0
    /// ^ Between -1 and 1
    ///     Negative values make the curve continuous, and more predictable (might be placebo)
    ///     Edit: I like 0.0 the best now. Feels more "direct"
    
    @objc lazy var accelerationCurve = standardAccelerationCurve
    
    @objc lazy var standardAccelerationCurve = { () -> AccelerationBezier in
        
        return ScrollConfig.accelerationCurveFromParams(pxPerTickBase:                                   self.pxPerTickBase,
                                                        pxPerTickEnd:                                    self.pxPerTickEnd,
                                                        consecutiveScrollTickIntervalMax:                self.consecutiveScrollTickIntervalMax,
                                                        consecutiveScrollTickInterval_AccelerationEnd:   self.consecutiveScrollTickInterval_AccelerationEnd,
                                                        accelerationHump:                                self.accelerationHump)
    }
    
    @objc lazy var preciseAccelerationCurve = { () -> AccelerationBezier in
        ScrollConfig.accelerationCurveFromParams(pxPerTickBase: 3, /// 2 is better than 3 but that leads to weird asswert failures in PixelatedAnimator that I can't be bothered to fix
                                                 pxPerTickEnd: 15,
                                                 consecutiveScrollTickIntervalMax: self.consecutiveScrollTickIntervalMax,
                                                 /// ^ We don't expect this to ever change so it's okay to just capture here
                                                 consecutiveScrollTickInterval_AccelerationEnd: self.consecutiveScrollTickInterval_AccelerationEnd,
                                                 accelerationHump: -0.2)
    }
    @objc lazy var quickAccelerationCurve = { () -> AccelerationBezier in
        ScrollConfig.accelerationCurveFromParams(pxPerTickBase: 80,
                                                 pxPerTickEnd: 400,
                                                 consecutiveScrollTickIntervalMax: self.consecutiveScrollTickIntervalMax,
                                                 consecutiveScrollTickInterval_AccelerationEnd: self.consecutiveScrollTickInterval_AccelerationEnd,
                                                 accelerationHump: -0.2)
    }
    
    // MARK: Keyboard modifiers
    
    /// Event flag masks
    @objc lazy var horizontalScrollModifierKeyMask = ScrollConfig.stringToEventFlagMask[mod["horizontalScrollModifierKey"] as! String] as! CGEventFlags
    @objc lazy var magnificationScrollModifierKeyMask = ScrollConfig.stringToEventFlagMask[mod["magnificationScrollModifierKey"] as! String] as! CGEventFlags
    
    /// Modifier enabled
    @objc lazy var horizontalScrollModifierKeyEnabled = mod["horizontalScrollModifierKeyEnabled"] as! Bool
    
    @objc lazy var magnificationScrollModifierKeyEnabled = mod["magnificationScrollModifierKeyEnabled"] as! Bool
    
    // MARK: - Helper functions
    
    fileprivate static func accelerationCurveFromParams(pxPerTickBase: Int, pxPerTickEnd: Int, consecutiveScrollTickIntervalMax: TimeInterval, consecutiveScrollTickInterval_AccelerationEnd: TimeInterval, accelerationHump: Double) -> AccelerationBezier {
        /**
         Define a curve describing the relationship between the scrollTickSpeed (in scrollTicks per second) (on the x-axis) and the pxPerTick (on the y axis).
         We'll call this function y(x).
         y(x) is composed of 3 other curves. The core of y(x) is a BezierCurve *b(x)*, which is defined on the interval (xMin, xMax).
         y(xMin) is called yMin and y(xMax) is called yMax
         There are two other components to y(x):
         - For `x < xMin`, we set y(x) to yMin
         - We do this so that the acceleration is turned off for tickSpeeds below xMin. Acceleration should only affect scrollTicks that feel 'consecutive' and not ones that feel like singular events unrelated to other scrollTicks. `self.consecutiveScrollTickIntervalMax` is (supposed to be) the maximum time between ticks where they feel consecutive. So we're using it to define xMin.
         - For `xMax < x`, we lineraly extrapolate b(x), such that the extrapolated line has the slope b'(xMax) and passes through (xMax, yMax)
         - We do this so the curve is defined and has reasonable values even when the user scrolls really fast
         (We use tick and step are interchangable here)
         
         HyperParameters:
         - `accelerationHump` controls how slope (sensitivity) increases around low scrollSpeeds. The name doesn't make sense but it's easy.
            I think this might be useful if  the basePxPerTick is very low. But for a larger basePxPerTick, it's probably fine to set it to 0
            - If `accelerationHump < 0`, that makes the transition between the preline and the Bezier smooth. (Makes the derivative continuous)
         - If the third controlPoint shouldn't be `(xMax, yMax)`. If it was, then the slope of the extrapolated curve after xMax would be affected `accelerationHump`.
         */
        
        /// Define Curve
        
        let xMin: Double = 1 / Double(consecutiveScrollTickIntervalMax)
        let yMin: Double = Double(pxPerTickBase);
        
        let xMax: Double = 1 / consecutiveScrollTickInterval_AccelerationEnd
        let yMax: Double = Double(pxPerTickEnd)
        
        let x2: Double
        let y2: Double
        
        if (accelerationHump < 0) {
            x2 = -accelerationHump
            y2 = 0
        } else {
            x2 = 0
            y2 = accelerationHump
        }
        
        /// Flatten out the end of the curve to prevent ridiculous pxPerTick outputs when input (tickSpeed) is very high. tickSpeed can be extremely high despite smoothing, because our time measurements of when ticks occur are very imprecise
        ///     Edit: Turn off flattening by making x3 = xMax. Do this because currenlty `consecutiveScrollTickIntervalMin == consecutiveScrollTickInterval_AccelerationEnd`, and therefore the extrapolated curve after xMax will never be used anyways -> I think this feels much nicer!
        let x3: Double = xMax /*(xMax-xMin)*0.9 + xMin*/
        let y3: Double = yMax
        
        typealias P = Bezier.Point
        return AccelerationBezier(controlPoints:
                                    [P(x: xMin, y: yMin),
                                     P(x: x2, y: y2),
                                     P(x: x3, y: y3),
                                     P(x: xMax, y: yMax)])
    }
    
    /// Copying
    ///     Why is there no simple default "shallowCopy" method for objects??
    ///     Be careful not to mutate anything in the copy because it mostly holds references
    
    func copy(with zone: NSZone? = nil) -> Any {
        
        /// Create new instance
        let copy = ScrollConfig()
        
        /// Iterate properties
        ///     And copy the values over to the new instance
        
        var numberOfProperties: UInt32 = 0
        let propertyList = class_copyPropertyList(ScrollConfig.self, &numberOfProperties)
        
        guard let propertyList = propertyList else { fatalError() }
        
        for i in 0..<(Int(numberOfProperties)) {
            
            let property = propertyList[i]
            
            /// Get property name
            let propertyNameC = property_getName(property)
            let propertyName = String(cString: propertyNameC)
            
            /// Debug
            DDLogDebug("Property: \(propertyName)")
            
            /// Check if property is readOnly
            var isReadOnly = false
            let readOnlyAttributeValue = property_copyAttributeValue(property, "R".cString(using: .utf8)!)
            isReadOnly = readOnlyAttributeValue != nil
            
            /// Skip copying this property if it's readonly
            if isReadOnly {
                DDLogDebug(" ... is readonly")
                continue
            }
            /// Copy over old value
            
            var oldValue = self.value(forKey: propertyName)
            
            if oldValue != nil {
                /// Make a copy of the oldValue if possible
                ///     Actually that should be unnecessary since we only override, not mutate the values
//                if let copyingOldValue = oldValue as? NSCopying {
//                    oldValue = copyingOldValue.copy()
//                } else {
//                    DDLogDebug("Not copying property: \(propertyName): \(oldValue)")
//                }
                copy.setValue(oldValue, forKey: propertyName)
            }
        }
        
        free(propertyList)
        
        return copy;
    }
    
    
    
}

