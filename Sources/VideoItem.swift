import Foundation
import Photos
import UIKit

enum ConversionStatus: Equatable {
    case pending
    case converting
    case completed
    case failed(String)
    
    var displayText: String {
        switch self {
        case .pending: return "В очереди"
        case .converting: return "Конвертация..."
        case .completed: return "Готово (Live Photo)"
        case .failed(let msg): return "Ошибка: \(msg)"
        }
    }
}

struct VideoItem: Identifiable {
    var id: String { asset.localIdentifier }
    let asset: PHAsset
    let duration: TimeInterval
    var thumbnail: UIImage?
    var status: ConversionStatus = .pending
    
    var formattedDuration: String {
        let seconds = Int(duration)
        let milliseconds = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d.%d сек", seconds, milliseconds)
    }
    
    var creationDateFormatted: String {
        guard let date = asset.creationDate else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
