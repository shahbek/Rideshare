import CoreGraphics

/// Chooses trailing, leading or upper-leading placement before clamping to the usable map viewport.
nonisolated enum MapBannerLayout {
    static func frame(anchor: CGPoint, size: CGSize, viewport: CGRect, lift: CGFloat = 0) -> CGRect {
        let size = CGSize(width: min(size.width, viewport.width), height: min(size.height, viewport.height))
        let headTop = anchor.y - 39 - lift
        let right = CGRect(x: anchor.x + 17, y: headTop, width: size.width, height: size.height)
        let left = CGRect(x: anchor.x - 17 - size.width, y: headTop, width: size.width, height: size.height)
        let upperLeft = CGRect(x: anchor.x + 11 - size.width, y: headTop - 6 - size.height, width: size.width, height: size.height)
        for candidate in [right, left, upperLeft] where viewport.contains(candidate) { return candidate }
        // A long label may not fit on either side. Slide it above the head, not across the head.
        let above = CGRect(x: min(max(upperLeft.minX, viewport.minX), viewport.maxX - size.width),
                           y: upperLeft.minY, width: size.width, height: size.height)
        if viewport.contains(above) { return above }
        let below = CGRect(x: above.minX, y: headTop + 28, width: size.width, height: size.height)
        if viewport.contains(below) { return below }
        let preferred = right.maxX <= viewport.maxX ? right : left
        return CGRect(
            x: min(max(preferred.minX, viewport.minX), viewport.maxX - size.width),
            y: min(max(preferred.minY, viewport.minY), viewport.maxY - size.height),
            width: size.width, height: size.height
        )
    }
}
