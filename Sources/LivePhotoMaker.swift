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
    
    /// Генерирует парные файлы для Live Photo из переданного AVAsset
    static func generateLivePhotoFiles(from avAsset: AVURLAsset) async throws -> LivePhotoFiles {
        let assetIdentifier = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let imageURL = tempDir.appendingPathComponent("image.jpg")
        let videoURL = tempDir.appendingPathComponent("video.mov")
        
        // 1. Извлекаем стоп-кадр (в начале видео, t = 0)
        let keyTime = CMTime(seconds: 0.0, preferredTimescale: 600)
        let frame = try await extractFrame(from: avAsset, at: keyTime)
        
        // 2. Записываем JPEG с MakerApple метаданными (ID 17 = Content Identifier)
        try writeImageWithMetadata(cgImage: frame, to: imageURL, assetIdentifier: assetIdentifier)
        
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
    
    private static func writeImageWithMetadata(cgImage: CGImage, to destinationURL: URL, assetIdentifier: String) throws {
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LivePhotoError.cannotCreateImageDestination
        }
        
        // В метаданных MakerApple (тег 17) указывается уникальный ID привязки к видео
        let makerAppleDict: [String: Any] = ["17": assetIdentifier]
        let metadata: [String: Any] = [
            kCGImagePropertyMakerAppleDictionary as String: makerAppleDict
        ]
        
        CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LivePhotoError.cannotCreateImageDestination
        }
    }
    
    private static func writeVideoWithMetadata(
        from sourceAsset: AVURLAsset,
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
        
        // Видеовывод и ввод (прямое сквозное копирование без пережатия для скорости и качества)
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
        
        writer.startSession(atSourceTime: .zero)
        
        // Записываем still image time timed metadata
        let stillTimeItem = AVMutableMetadataItem()
        stillTimeItem.key = stillTimeKey as NSString
        stillTimeItem.keySpace = .quickTimeMetadata
        stillTimeItem.value = 0 as NSNumber // 0 мс / начало видео
        stillTimeItem.dataType = stillTimeDataType
        
        let timedMetadataGroup = AVTimedMetadataGroup(
            items: [stillTimeItem],
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 600))
        )
        metadataAdaptor.append(timedMetadataGroup)
        
        // Копируем семплы видео
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "livephoto.video.processing")
            videoInput.requestMediaDataWhenReady(on: queue) {
                while videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        videoInput.append(sample)
                    } else {
                        videoInput.markAsFinished()
                        continuation.resume()
                        break
                    }
                }
            }
        }
        
        // Копируем семплы аудио если есть
        if let aInput = audioInput, let aOutput = audioOutput {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let queue = DispatchQueue(label: "livephoto.audio.processing")
                aInput.requestMediaDataWhenReady(on: queue) {
                    while aInput.isReadyForMoreMediaData {
                        if let sample = aOutput.copyNextSampleBuffer() {
                            aInput.append(sample)
                        } else {
                            aInput.markAsFinished()
                            continuation.resume()
                            break
                        }
                    }
                }
            }
        }
        
        metadataInput.markAsFinished()
        
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? LivePhotoError.exportFailed
        }
    }
}
