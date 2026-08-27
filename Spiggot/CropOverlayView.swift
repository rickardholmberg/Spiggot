//
//  CropOverlayView.swift
//  Spiggot
//
//  A draggable/resizable crop-box overlay, drawn on top of a live preview
//  NSImageView in SettingsWindowController. Works entirely in normalized
//  (0...1) coordinates so it doesn't need to know the preview's pixel size.
//

import Cocoa

final class CropOverlayView: NSView {
    private enum HandleKind {
        case none
        case move
        case corner(dx: CGFloat, dy: CGFloat)  // dx/dy: -1 or +1, which corner
        case edge(dx: CGFloat, dy: CGFloat)    // dx or dy is 0, the other -1/+1
    }

    /// Crop box in normalized (0...1) view coordinates, origin at bottom-left
    /// (matches CGRect/AppKit convention) to line up 1:1 with CameraCapture.cropRect.
    var normalizedRect: CGRect = CameraCapture.fullFrameCropRect {
        didSet { needsDisplay = true }
    }

    /// Desired *pixel* aspect ratio (width / height) of the crop, or nil for
    /// free-form resize. E.g. 16.0/9.0 to exactly fill OBS's canvas.
    private var desiredPixelAspectRatio: CGFloat?

    /// The source frame's actual pixel aspect ratio (width / height), from
    /// the live preview image. Normalized-rect coordinates are fractions of
    /// the source frame's width/height independently, so a target *pixel*
    /// ratio only maps to a *normalized-rect* ratio of the same number when
    /// the source happens to be square -- this corrects for that.
    private var sourceAspectRatio: CGFloat = 1.0

    /// The aspect ratio to actually enforce on the normalized rect, or nil
    /// for free-form. `nil` whenever there's no pixel-ratio target.
    private var effectiveAspectRatio: CGFloat? {
        guard let desiredPixelAspectRatio else { return nil }
        return desiredPixelAspectRatio / sourceAspectRatio
    }

    var onRectChanged: ((CGRect) -> Void)?

    private let handleSize: CGFloat = 8
    private let hitSlop: CGFloat = 6
    private var activeHandle: HandleKind = .none
    private var dragStartRect: CGRect = .zero
    private var dragStartPoint: NSPoint = .zero

    override var isFlipped: Bool { false }

    /// Sets a new target *pixel* aspect ratio (e.g. 16.0/9.0), snapping the
    /// current rect to match (keeping it centered) rather than resetting to
    /// full-frame. Pass nil for free-form.
    func setDesiredPixelAspectRatio(_ ratio: CGFloat?) {
        desiredPixelAspectRatio = ratio
        guard let effectiveAspectRatio else {
            needsDisplay = true
            return
        }
        normalizedRect = Self.snapped(normalizedRect, toAspectRatio: effectiveAspectRatio)
        needsDisplay = true
        onRectChanged?(normalizedRect)
    }

    /// Updates the source frame's pixel aspect ratio (call this whenever a
    /// new preview frame arrives). Re-snaps the box only when the ratio
    /// actually changes (e.g. first frame arriving, or the camera switching
    /// resolution/orientation), not on every single frame.
    func setSourceAspectRatio(_ ratio: CGFloat) {
        guard ratio > 0, abs(ratio - sourceAspectRatio) > 0.001 else { return }
        sourceAspectRatio = ratio
        guard let effectiveAspectRatio else { return }
        normalizedRect = Self.snapped(normalizedRect, toAspectRatio: effectiveAspectRatio)
        needsDisplay = true
        onRectChanged?(normalizedRect)
    }

    private static func snapped(_ rect: CGRect, toAspectRatio ratio: CGFloat) -> CGRect {
        let centerX = rect.midX
        let centerY = rect.midY
        var width = rect.width
        var height = width / ratio
        if height > rect.height {
            height = rect.height
            width = height * ratio
        }
        var newRect = CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
        newRect = Self.clamped(newRect)
        return newRect
    }

    private static func clamped(_ rect: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(max(r.width, 0.02), 1.0)
        r.size.height = min(max(r.height, 0.02), 1.0)
        r.origin.x = min(max(r.origin.x, 0), 1 - r.width)
        r.origin.y = min(max(r.origin.y, 0), 1 - r.height)
        return r
    }

    /// The sub-rect of `bounds` the source image actually occupies. The
    /// preview `NSImageView` aspect-fits the image (matching `.scaleProportionallyUpOrDown`),
    /// so whenever the source's aspect ratio differs from this view's own
    /// (very common -- e.g. a 3:2 camera in a 16:9 preview box), the visible
    /// picture is letterboxed/pillarboxed *inside* `bounds`. Every coordinate
    /// conversion below must go through this, not raw `bounds`, or the crop
    /// box drifts away from where the actual photo is being displayed.
    private func imageDisplayRect() -> CGRect {
        guard bounds.width > 0, bounds.height > 0, sourceAspectRatio > 0 else { return bounds }
        let boundsAspect = bounds.width / bounds.height
        if sourceAspectRatio > boundsAspect {
            // Image is relatively wider than the box: fits full width, letterboxed top/bottom.
            let height = bounds.width / sourceAspectRatio
            return CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        } else {
            // Image is relatively taller/narrower: fits full height, pillarboxed left/right.
            let width = bounds.height * sourceAspectRatio
            return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
        }
    }

    private func rectInView() -> CGRect {
        let imageRect = imageDisplayRect()
        return CGRect(
            x: imageRect.minX + normalizedRect.minX * imageRect.width,
            y: imageRect.minY + normalizedRect.minY * imageRect.height,
            width: normalizedRect.width * imageRect.width,
            height: normalizedRect.height * imageRect.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let box = rectInView()

        NSColor.black.withAlphaComponent(0.5).setFill()
        let dimPath = NSBezierPath(rect: bounds)
        dimPath.append(NSBezierPath(rect: box).reversed)
        dimPath.fill()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: box)
        border.lineWidth = 1.5
        border.stroke()

        for handle in handlePositions() {
            let handleRect = CGRect(
                x: handle.x - handleSize / 2, y: handle.y - handleSize / 2,
                width: handleSize, height: handleSize
            )
            NSColor.white.setFill()
            NSBezierPath(rect: handleRect).fill()
        }
    }

    /// Corner handles always; edge handles only when free-form (aspect-locked
    /// resize only makes sense from a corner, so edges are hidden then).
    private func handlePositions() -> [CGPoint] {
        let box = rectInView()
        var points: [CGPoint] = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY),
            CGPoint(x: box.maxX, y: box.maxY),
        ]
        if effectiveAspectRatio == nil {
            points.append(contentsOf: [
                CGPoint(x: box.midX, y: box.minY),
                CGPoint(x: box.midX, y: box.maxY),
                CGPoint(x: box.minX, y: box.midY),
                CGPoint(x: box.maxX, y: box.midY),
            ])
        }
        return points
    }

    private func handle(at point: NSPoint) -> HandleKind {
        let box = rectInView()

        func near(_ p: CGPoint) -> Bool {
            abs(point.x - p.x) <= handleSize / 2 + hitSlop && abs(point.y - p.y) <= handleSize / 2 + hitSlop
        }

        if near(CGPoint(x: box.minX, y: box.minY)) { return .corner(dx: -1, dy: -1) }
        if near(CGPoint(x: box.maxX, y: box.minY)) { return .corner(dx: 1, dy: -1) }
        if near(CGPoint(x: box.minX, y: box.maxY)) { return .corner(dx: -1, dy: 1) }
        if near(CGPoint(x: box.maxX, y: box.maxY)) { return .corner(dx: 1, dy: 1) }

        if effectiveAspectRatio == nil {
            if near(CGPoint(x: box.midX, y: box.minY)) { return .edge(dx: 0, dy: -1) }
            if near(CGPoint(x: box.midX, y: box.maxY)) { return .edge(dx: 0, dy: 1) }
            if near(CGPoint(x: box.minX, y: box.midY)) { return .edge(dx: -1, dy: 0) }
            if near(CGPoint(x: box.maxX, y: box.midY)) { return .edge(dx: 1, dy: 0) }
        }

        if box.insetBy(dx: hitSlop, dy: hitSlop).contains(point) { return .move }
        if box.contains(point) { return .move }
        return .none
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        activeHandle = handle(at: point)
        dragStartRect = normalizedRect
        dragStartPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        let imageRect = imageDisplayRect()
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dxView = point.x - dragStartPoint.x
        let dyView = point.y - dragStartPoint.y
        let dx = dxView / imageRect.width
        let dy = dyView / imageRect.height

        var newRect = dragStartRect

        switch activeHandle {
        case .none:
            return

        case .move:
            newRect.origin.x += dx
            newRect.origin.y += dy

        case .edge(let edx, let edy):
            if edx != 0 {
                if edx > 0 {
                    newRect.size.width = dragStartRect.width + dx
                } else {
                    newRect.origin.x = dragStartRect.minX + dx
                    newRect.size.width = dragStartRect.width - dx
                }
            }
            if edy != 0 {
                if edy > 0 {
                    newRect.size.height = dragStartRect.height + dy
                } else {
                    newRect.origin.y = dragStartRect.minY + dy
                    newRect.size.height = dragStartRect.height - dy
                }
            }

        case .corner(let cdx, let cdy):
            if let ratio = effectiveAspectRatio {
                // Uniform resize from the opposite corner: derive a candidate
                // width from each axis, use whichever moved further, then
                // recompute the other dimension from the locked ratio.
                let widthDelta = cdx > 0 ? dx : -dx
                let heightDelta = cdy > 0 ? dy : -dy
                let widthFromWidth = dragStartRect.width + widthDelta
                let widthFromHeight = (dragStartRect.height + heightDelta) * ratio
                let newWidth = max(
                    abs(widthDelta) > abs(heightDelta) * ratio ? widthFromWidth : widthFromHeight,
                    0.02
                )
                let newHeight = newWidth / ratio

                let anchorX = cdx > 0 ? dragStartRect.minX : dragStartRect.maxX
                let anchorY = cdy > 0 ? dragStartRect.minY : dragStartRect.maxY
                newRect.size.width = newWidth
                newRect.size.height = newHeight
                newRect.origin.x = cdx > 0 ? anchorX : anchorX - newWidth
                newRect.origin.y = cdy > 0 ? anchorY : anchorY - newHeight
            } else {
                if cdx > 0 {
                    newRect.size.width = dragStartRect.width + dx
                } else {
                    newRect.origin.x = dragStartRect.minX + dx
                    newRect.size.width = dragStartRect.width - dx
                }
                if cdy > 0 {
                    newRect.size.height = dragStartRect.height + dy
                } else {
                    newRect.origin.y = dragStartRect.minY + dy
                    newRect.size.height = dragStartRect.height - dy
                }
            }
        }

        normalizedRect = Self.clamped(newRect)
        onRectChanged?(normalizedRect)
    }

    override func mouseUp(with event: NSEvent) {
        activeHandle = .none
    }
}
