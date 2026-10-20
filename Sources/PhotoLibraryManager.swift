import Foundation
import Photos
import UIKit
import Combine

@MainActor
final class PhotoLibraryManager: ObservableObject {
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var videos: [VideoItem] = []
    @Published var isScanning: Bool = false
    @Published var isConverting: Bool = false
    @Published var currentProgress: Double = 0.0
    @Published var progressMessage: String = ""
    @Published var minDuration: Double = 2.0
    @Published var maxDuration: Double = 3.0
    @Published var deleteOriginalsAfterConversion: Bool = true
    @Published var statusLog: [String] = []
    
    private let imageManager = PHCachingImageManager()
    
    init() {
        checkPermission()
    }
    
    func checkPermission() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }
    
    func requestPermission() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            Task { @MainActor in
                self?.authorizationStatus = status
                if status == .authorized || status == .limited {
                    self?.scanForVideos()
                }
            }
        }
    }
    
    // MARK: - Сканирование видеозаписей
    
    func scanForVideos() {
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            return
        }
        
        isScanning = true
        videos.removeAll()
        appendLog("Поиск видео длительностью от \(String(format: "%.1f", minDuration)) до \(String(format: "%.1f", maxDuration)) сек...")
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        
        let results = PHAsset.fetchAssets(with: fetchOptions)
        var foundItems: [VideoItem] = []
        
        results.enumerateObjects { asset, _, _ in
            let duration = asset.duration
            // Проверяем диапазон (например, от 2.0 до 3.0 секунд)
            if duration >= self.minDuration && duration <= self.maxDuration {
                let item = VideoItem(asset: asset, duration: duration, thumbnail: nil, status: .pending)
                foundItems.append(item)
            }
        }
        
        self.videos = foundItems
        self.isScanning = false
        appendLog("Найдено подходящих видео: \(foundItems.count)")
        
        // Загружаем превьюшки асинхронно
        loadThumbnails()
    }
    
    private func loadThumbnails() {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        let targetSize = CGSize(width: 160, height: 160)
        
        for (index, item) in videos.enumerated() {
            imageManager.requestImage(for: item.asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { [weak self] image, _ in
                guard let self = self, let image = image else { return }
                Task { @MainActor in
                    if index < self.videos.count && self.videos[index].id == item.id {
                        self.videos[index].thumbnail = image
                    }
                }
            }
        }
    }
    
    // MARK: - Пакетная конвертация в Live Photo и удаление оригиналов
    
    func convertAllVideos() async {
        guard !videos.isEmpty else { return }
        
        isConverting = true
        currentProgress = 0.0
        let total = Double(videos.count)
        var successfulAssetsToDelete: [PHAsset] = []
        var successCount = 0
        var failCount = 0
        
        appendLog("Старт конвертации \(videos.count) видео в Live Photo...")
        
        for index in 0..<videos.count {
            let item = videos[index]
            videos[index].status = .converting
            progressMessage = "Обработка \(index + 1) из \(videos.count)"
            
            do {
                // 1. Получаем AVAsset (подходит как обычное видео, так и замедленное/отредактированное)
                let avAsset = try await requestAVAsset(for: item.asset)
                
                // 2. Генерируем парные файлы Live Photo
                let files = try await LivePhotoMaker.generateLivePhotoFiles(from: avAsset)
                
                // 3. Сохраняем Live Photo в библиотеку
                try await saveLivePhoto(files: files)
                
                // Очищаем временные файлы
                files.cleanup()
                
                // 4. Помечаем как успешный
                videos[index].status = .completed
                successfulAssetsToDelete.append(item.asset)
                successCount += 1
                appendLog("✓ Сконвертировано: \(item.id) (\(item.formattedDuration))")
                
            } catch {
                videos[index].status = .failed(error.localizedDescription)
                failCount += 1
                appendLog("✗ Ошибка для \(item.id): \(error.localizedDescription)")
            }
            
            currentProgress = Double(index + 1) / total
        }
        
        // 5. Удаляем оригинальные видео в одном системном диалоге (единый запрос)
        if deleteOriginalsAfterConversion && !successfulAssetsToDelete.isEmpty {
            progressMessage = "Запрос подтверждения удаления исходных видео..."
            appendLog("Удаление \(successfulAssetsToDelete.count) исходных видеофайлов...")
            
            do {
                try await deleteAssets(successfulAssetsToDelete)
                appendLog("✓ Исходные видео успешно удалены из медиатеки")
                // Удаляем сконвертированные элементы из текущего списка отображения
                videos.removeAll { item in
                    successfulAssetsToDelete.contains(where: { $0.localIdentifier == item.id })
                }
            } catch {
                appendLog("Предупреждение: Не удалось удалить оригинальные видео (\(error.localizedDescription)). Возможно, пользователь отклонил запрос.")
            }
        }
        
        isConverting = false
        progressMessage = "Завершено! Успешно: \(successCount), Ошибок: \(failCount)"
        appendLog("Готово! Создано Live Photo: \(successCount).")
    }
    
    // MARK: - Вспомогательные методы работы с PhotoKit
    
    private func requestAVAsset(for asset: PHAsset) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var isResumed = false
            
            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                lock.lock()
                guard !isResumed else {
                    lock.unlock()
                    return
                }
                isResumed = true
                lock.unlock()
                
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if let avAsset = avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    continuation.resume(throwing: LivePhotoMaker.LivePhotoError.cannotLoadAsset)
                }
            }
        }
    }
    
    private func saveLivePhoto(files: LivePhotoMaker.LivePhotoFiles) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            
            let photoOptions = PHAssetResourceCreationOptions()
            photoOptions.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: files.imageURL, options: photoOptions)
            
            let videoOptions = PHAssetResourceCreationOptions()
            videoOptions.shouldMoveFile = false
            request.addResource(with: .pairedVideo, fileURL: files.videoURL, options: videoOptions)
        }
    }
    
    private func deleteAssets(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
    
    private func appendLog(_ message: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        statusLog.append("[\(time)] \(message)")
    }
}
