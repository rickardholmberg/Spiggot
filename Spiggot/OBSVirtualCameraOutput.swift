//
//  OBSVirtualCameraOutput.swift
//  Spiggot
//
//  Publishes frames directly into OBS Studio's "OBS Camera Extension" virtual
//  camera device, without launching OBS Studio itself and without needing
//  OSSystemExtensionManager/any entitlement: the extension's sink stream
//  authorizes any client unconditionally (see OBSCameraStreamSink.swift in
//  obs-studio's mac-virtualcam plugin), so this only uses plain CoreMediaIO
//  client APIs (the same ones any camera-reading app uses). This requires
//  OBS Studio to have been installed and run at least once on this Mac, so
//  its camera extension is activated and registered with the system.

import CoreImage
import CoreMediaIO
import CoreVideo
import Foundation

struct OBSVirtualCameraError: Error, CustomStringConvertible {
    let description: String
}

final class OBSVirtualCameraOutput {
    // Public constant shared by every OBS build (obs-studio/CMakePresets.json),
    // confirmed to match the installed extension via its Info.plist.
    private static let deviceUUIDString = "7626645E-4425-469E-9D8B-97E0FA59AC75"

    // Fixed canvas the extension's device declares (OBSCameraDeviceSource.swift).
    private static let canvasWidth = 1920
    private static let canvasHeight = 1080
    private static let maxPublishHz: Double = 30.0
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()

    private var deviceID: CMIODeviceID?
    private var sinkStreamID: CMIOStreamID?
    private var simpleQueue: CMSimpleQueue?
    private var pixelBufferPool: CVPixelBufferPool?
    private var formatDescription: CMFormatDescription?
    private var lastPublishTime: CFAbsoluteTime = 0

    var isStarted: Bool { deviceID != nil && sinkStreamID != nil }

    /// Cheap presence check (no stream start) so callers can validate OBS's
    /// extension is reachable before committing to enabling output -- e.g.
    /// while capture isn't running yet, when `start()` won't be called.
    static func isExtensionAvailable() -> Bool {
        findDeviceAndSinkStream() != nil
    }

    /// Finds the OBS camera device, starts its sink stream, and prepares the
    /// pixel buffer pool. Returns false (non-fatal) if OBS's extension isn't
    /// active on this Mac -- that's a normal "not installed/approved yet" state.
    func start() -> Result<Void, OBSVirtualCameraError> {
        guard !isStarted else { return .success(()) }

        guard let (device, sink) = Self.findDeviceAndSinkStream() else {
            return .failure(OBSVirtualCameraError(description: "OBS Camera Extension not found (install/run OBS Studio once to activate it)"))
        }

        let startResult = CMIODeviceStartStream(device, sink)
        guard startResult == noErr else {
            return .failure(OBSVirtualCameraError(description: "CMIODeviceStartStream failed (\(startResult))"))
        }

        var queueUnmanaged: Unmanaged<CMSimpleQueue>?
        CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queueUnmanaged)
        guard let queueUnmanaged else {
            CMIODeviceStopStream(device, sink)
            return .failure(OBSVirtualCameraError(description: "Failed to get OBS sink buffer queue"))
        }

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(Self.canvasWidth),
            height: Int32(Self.canvasHeight),
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        var pool: CVPixelBufferPool?
        let pbAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Self.canvasWidth,
            kCVPixelBufferHeightKey: Self.canvasHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pbAttrs as CFDictionary, &pool)
        guard let pool else {
            CMIODeviceStopStream(device, sink)
            return .failure(OBSVirtualCameraError(description: "Failed to create OBS pixel buffer pool"))
        }

        self.deviceID = device
        self.sinkStreamID = sink
        self.simpleQueue = queueUnmanaged.takeRetainedValue()
        self.formatDescription = formatDescription
        self.pixelBufferPool = pool
        self.lastPublishTime = 0
        return .success(())
    }

    func stop() {
        if let deviceID, let sinkStreamID {
            CMIODeviceStopStream(deviceID, sinkStreamID)
        }
        deviceID = nil
        sinkStreamID = nil
        simpleQueue = nil
        pixelBufferPool = nil
        formatDescription = nil
    }

    /// Aspect-fits `image` into the extension's fixed canvas and enqueues it.
    /// Rate-limited independently of the source frame rate, since the sink's
    /// own buffer queue only holds a single pending frame.
    func publish(_ image: CIImage, ciContext: CIContext) {
        guard let simpleQueue, let pool = pixelBufferPool, let formatDescription = formatDescription else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPublishTime >= 1.0 / Self.maxPublishHz else { return }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
            let pixelBuffer
        else { return }

        let srcExtent = image.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return }
        let scale = min(
            Double(Self.canvasWidth) / srcExtent.width,
            Double(Self.canvasHeight) / srcExtent.height
        )
        let scaledWidth = srcExtent.width * CGFloat(scale)
        let scaledHeight = srcExtent.height * CGFloat(scale)
        let tx = (CGFloat(Self.canvasWidth) - scaledWidth) / 2.0
        let ty = (CGFloat(Self.canvasHeight) - scaledHeight) / 2.0
        let fitted = image
            .transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))

        let canvasRect = CGRect(x: 0, y: 0, width: Self.canvasWidth, height: Self.canvasHeight)
        // Pooled pixel buffers are recycled, not zeroed -- when `fitted`
        // doesn't cover the whole canvas (any aspect ratio other than
        // exactly 16:9), the uncovered letterbox/pillarbox area must be
        // explicitly painted black, or it shows whatever garbage was left
        // over from a previous frame's contents in that buffer. Skip the
        // extra composite/blend pass entirely in the common case where the
        // crop is already locked to 16:9 and `fitted` fills the canvas
        // exactly -- there's nothing to paint around.
        let fillsCanvas = abs(scaledWidth - CGFloat(Self.canvasWidth)) < 1
            && abs(scaledHeight - CGFloat(Self.canvasHeight)) < 1
        let toRender: CIImage
        if fillsCanvas {
            toRender = fitted
        } else {
            let background = CIImage(color: .black).cropped(to: canvasRect)
            toRender = fitted.composited(over: background)
        }

        ciContext.render(
            toRender,
            to: pixelBuffer,
            bounds: canvasRect,
            colorSpace: Self.deviceRGB
        )

        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo()
        timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        let err = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        guard err == noErr, let sampleBuffer else { return }

        CMSimpleQueueEnqueue(simpleQueue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
        lastPublishTime = now
    }

    private static func findDeviceAndSinkStream() -> (CMIODeviceID, CMIOStreamID)? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize)
        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        guard count > 0 else { return nil }
        var devices = [CMIODeviceID](repeating: 0, count: count)
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &used, &devices)

        guard let targetUUID = CFUUIDCreateFromString(kCFAllocatorDefault, deviceUUIDString as CFString) else {
            return nil
        }

        for device in devices {
            var uidAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var uidSize: UInt32 = 0
            CMIOObjectGetPropertyDataSize(device, &uidAddress, 0, nil, &uidSize)
            guard uidSize > 0 else { continue }
            var uidRef: CFString?
            var uidUsed: UInt32 = 0
            withUnsafeMutablePointer(to: &uidRef) { ptr in
                _ = CMIOObjectGetPropertyData(device, &uidAddress, 0, nil, uidSize, &uidUsed, ptr)
            }
            guard let uid = uidRef, let deviceUUID = CFUUIDCreateFromString(kCFAllocatorDefault, uid) else {
                continue
            }
            guard CFEqual(deviceUUID, targetUUID) else { continue }

            var streamsAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var streamsSize: UInt32 = 0
            CMIOObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize)
            let streamCount = Int(streamsSize) / MemoryLayout<CMIOStreamID>.size
            guard streamCount >= 2 else { continue }
            var streamIDs = [CMIOStreamID](repeating: 0, count: streamCount)
            var streamsUsed: UInt32 = 0
            CMIOObjectGetPropertyData(device, &streamsAddress, 0, nil, streamsSize, &streamsUsed, &streamIDs)

            // Stream[0] = source (read side, consumers), Stream[1] = sink (write
            // side, producers) -- matches the add order in OBSCameraDeviceSource.swift.
            return (device, streamIDs[1])
        }
        return nil
    }
}
