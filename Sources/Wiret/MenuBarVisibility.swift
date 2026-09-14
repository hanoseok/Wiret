import CoreGraphics

enum MenuBarVisibility {
    /// Returns true when the status item frame is placed in the visible right-hand status area.
    /// - itemFrame: status item window frame (screen coords)
    /// - rightArea: NSScreen.auxiliaryTopRightArea (nil on screens without a notch → always visible)
    /// - screenFrame: the screen's frame
    static func isItemVisible(itemFrame: CGRect, rightArea: CGRect?, screenFrame: CGRect) -> Bool {
        if itemFrame.isEmpty {
            return false
        }

        if let rightArea {
            return itemFrame.minX >= rightArea.minX && itemFrame.maxX <= rightArea.maxX
        }

        return itemFrame.minX >= screenFrame.minX && itemFrame.maxX <= screenFrame.maxX
    }
}
