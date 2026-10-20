import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Класс, отвечающий за создание парных файлов (изображение JPEG/HEIC + видео QuickTime MOV)
/// со специальными метаданными Apple для формирования полноценного Live Photo.
final class LivePhotoMaker {
    
    enum LivePhotoError: LocalizedError {
        case cannotLoadAsset
        case cannotExtractFrame
        case cannotCreateImageDestination
        case cannotSetupAssetReader
        case cannotSetupAssetWriter
        case exportFailed
        
        var errorDescription: String? {
            switch self {
            case .cannotLoadAsset: return "Не удалось загрузить видеофайл"
            case .cannotExtractFrame: return "Не удалось извлечь стоп-кадр из видео"
            case .cannotCreateImageDestination: return "Ошибка при сохранении метаданных изображения"
            case .cannotSetupAssetReader: return "Ошибка чтения видеотрека"
            case .cannotSetupAssetWriter: return "Ошибка записи QuickTime контейнера"
            case .exportFailed: return "Не удалось завершить экспорт Live Photo"
            }
        }
    }
    
    struct LivePhotoFiles {
        let imageURL: URL
        let videoURL: URL
        let assetIdentifier: String
        
        func cleanup() {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: videoURL)
        }
    }
    
    /// Генерирует парные файлы для Live Photo из переданного AVAsset (любого типа, включая AVComposition)
    static func generateLivePhotoFiles(from avAsset: AVAsset, creationDate: Date? = nil) async throws -> LivePhotoFiles {
        let assetIdentifier = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let imageURL = tempDir.appendingPathComponent("image.jpg")
        let videoURL = tempDir.appendingPathComponent("video.mov")
        
        // 1. Извлекаем стоп-кадр (в начале видео, t = 0)
        let keyTime = CMTime(seconds: 0.0, preferredTimescale: 600)
        let frame = try await extractFrame(from: avAsset, at: keyTime)
        
        // 2. Записываем JPEG с MakerApple метаданными (ID 17 = Content Identifier) и датой съемки EXIF
        try writeImageWithMetadata(cgImage: frame, to: imageURL, assetIdentifier: assetIdentifier, creationDate: creationDate)
        
        // 3. Перепаковываем видео в QuickTime MOV с метаданными com.apple.quicktime.content-identifier
        // и com.apple.quicktime.still-image-time
        try await writeVideoWithMetadata(from: avAsset, to: videoURL, assetIdentifier: assetIdentifier, stillImageTime: keyTime)
        
        return LivePhotoFiles(imageURL: imageURL, videoURL: videoURL, assetIdentifier: assetIdentifier)
    }
    
    // MARK: - Private Helpers
    
    private static func extractFrame(from asset: AVAsset, at time: CMTime) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        return try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let cgImage = cgImage {
                    continuation.resume(returning: cgImage)
                } else {
                    continuation.resume(throwing: LivePhotoError.cannotExtractFrame)
                }
            }
        }
    }
    
    private static func writeImageWithMetadata(cgImage: CGImage, to destinationURL: URL, assetIdentifier: String, creationDate: Date? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LivePhotoError.cannotCreateImageDestination
        }
        
        // В метаданных MakerApple (тег 17) указывается уникальный ID привязки к видео
        let makerAppleDict: [String: Any] = ["17": assetIdentifier]
        var metadata: [String: Any] = [
            kCGImagePropertyMakerAppleDictionary as String: makerAppleDict
        ]
        
        if let date = creationDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let dateStr = formatter.string(from: date)
            metadata[kCGImagePropertyExifDictionary as String] = [
                kCGImagePropertyExifDateTimeOriginal as String: dateStr,
                kCGImagePropertyExifDateTimeDigitized as String: dateStr
            ]
            metadata[kCGImagePropertyTIFFDictionary as String] = [
                kCGImagePropertyTIFFDateTime as String: dateStr
            ]
        }
        
        CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LivePhotoError.cannotCreateImageDestination
        }
    }
    
    private static func writeVideoWithMetadata(
        from sourceAsset: AVAsset,
        to targetURL: URL,
        assetIdentifier: String,
        stillImageTime: CMTime
    ) async throws {
        let reader = try AVAssetReader(asset: sourceAsset)
        let writer = try AVAssetWriter(outputURL: targetURL, fileType: .mov)
        
        // Метаданные контейнера QuickTime: Content Identifier
        let item = AVMutableMetadataItem()
        item.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier as NSString
        item.keySpace = .quickTimeMetadata
        item.value = assetIdentifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [item]
        
        // Загружаем видеотрек
        let videoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw LivePhotoError.cannotSetupAssetReader
        }
        
        let videoFormatDesc = try await videoTrack.load(.formatDescriptions).first
        
        // Видеовывод и ввод
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormatDesc)
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        videoInput.expectsMediaDataInRealTime = false
        
        if reader.canAdd(videoOutput) {
            reader.add(videoOutput)
        }
        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        }
        
        // Аудиотрек (если есть)
        let audioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack = audioTracks.first {
            let audioFormatDesc = try await audioTrack.load(.formatDescriptions).first
            let aOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormatDesc)
            aInput.expectsMediaDataInRealTime = false
            
            if reader.canAdd(aOutput) && writer.canAdd(aInput) {
                reader.add(aOutput)
                writer.add(aInput)
                audioOutput = aOutput
                audioInput = aInput
            }
        }
        
        // Создаем дорожку timed metadata для still-image-time
        let stillTimeKey = "com.apple.quicktime.still-image-time"
        let stillTimeIdentifier = "\(AVMetadataKeySpace.quickTimeMetadata.rawValue)/\(stillTimeKey)"
        let stillTimeDataType = "com.apple.metadata.datatype.int8"
        
        let stillTimeSpec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: stillTimeIdentifier,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: stillTimeDataType
        ]
        
        var stillTimeFormatDescription: CMMetadataFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [stillTimeSpec] as CFArray,
            formatDescriptionOut: &stillTimeFormatDescription
        )
        
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: stillTimeFormatDescription)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        
        if writer.canAdd(metadataInput) {
            writer.add(metadataInput)
        }
        
        guard reader.startReading() else {
            throw LivePhotoError.cannotSetupAssetReader
        }
        guard writer.startWriting() else {
            throw LivePhotoError.cannotSetupAssetWriter
        }
        
        // ПАРАЛЛЕЛЬНАЯ запись видео и аудио через DispatchGroup для исключения взаимных блокировок буфера
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "livephoto.muxer.queue", qos: .userInitiated)
            let group = DispatchGroup()
            let lock = NSLock()
            var sessionStarted = false
            
            group.enter()
            videoInput.requestMediaDataWhenReady(on: queue) {
                while videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        lock.lock()
                        if !sessionStarted {
                            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                            writer.startSession(atSourceTime: pts)
                            
                            // Записываем still image time и сразу отмечаем метадорожку завершенной
                            let stillTimeItem = AVMutableMetadataItem()
                            stillTimeItem.key = stillTimeKey as NSString
                            stillTimeItem.keySpace = .quickTimeMetadata
                            stillTimeItem.value = 0 as NSNumber
                            stillTimeItem.dataType = stillTimeDataType
                            
                            let timedGroup = AVTimedMetadataGroup(
                                items: [stillTimeItem],
                                timeRange: CMTimeRange(start: pts, duration: CMTime(value: 1, timescale: 600))
                            )
                            metadataAdaptor.append(timedGroup)
                            metadataInput.markAsFinished()
                            
                            sessionStarted = true
                        }
                        lock.unlock()
                        
                        videoInput.append(sample)
                    } else {
                        videoInput.markAsFinished()
                        group.leave()
                        break
                    }
                }
            }
            
            if let aInput = audioInput, let aOutput = audioOutput {
                group.enter()
                aInput.requestMediaDataWhenReady(on: queue) {
                    while aInput.isReadyForMoreMediaData {
                        if let sample = aOutput.copyNextSampleBuffer() {
                            lock.lock()
                            let started = sessionStarted
                            lock.unlock()
                            if started {
                                aInput.append(sample)
                            }
                        } else {
                            aInput.markAsFinished()
                            group.leave()
                            break
                        }
                    }
                }
            }
            
            group.notify(queue: queue) {
                continuation.resume()
            }
        }
        
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? LivePhotoError.exportFailed
        }
    }
}
