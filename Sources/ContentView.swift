import SwiftUI
import Photos

struct ContentView: View {
    @EnvironmentObject var manager: PhotoLibraryManager
    @State private var showLogsSheet = false
    @State private var showDateSyncSheet = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch manager.authorizationStatus {
                case .notDetermined:
                    permissionRequestView
                case .restricted, .denied:
                    permissionDeniedView
                case .authorized, .limited:
                    mainContentView
                @unknown default:
                    Text("Неизвестный статус доступа")
                }
            }
            .navigationTitle("Live Photo Converter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showDateSyncSheet = true
                    } label: {
                        Label("Даты", systemImage: "calendar.badge.clock")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showLogsSheet = true
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                }
            }
            .sheet(isPresented: $showLogsSheet) {
                logsSheetView
            }
            .sheet(isPresented: $showDateSyncSheet) {
                dateSyncSheetView
            }
        }
    }
    
    // MARK: - Views авторизации
    
    private var permissionRequestView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "livephoto.badge.automatic")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(.blue)
            
            Text("Доступ к Фото")
                .font(.title2.bold())
            
            Text("Приложению требуется доступ к вашей медиатеке для поиска коротких видео (2-3 сек), их конвертации в Live Photo и удаления исходных роликов.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)
            
            Button {
                manager.requestPermission()
            } label: {
                Text("Разрешить доступ")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            
            Spacer()
        }
    }
    
    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            
            Text("Доступ ограничен")
                .font(.title3.bold())
            
            Text("Пожалуйста, перейдите в Настройки iOS и откройте полный доступ к приложению «Фото».")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Button("Открыть Настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding()
    }
    
    // MARK: - Главный экран
    
    private var mainContentView: some View {
        VStack(spacing: 0) {
            // Панель настроек поиска
            filterSection
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground))
            
            // Список найденных видео
            if manager.isScanning {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView("Сканирование медиатеки...")
                    Spacer()
                }
            } else if manager.videos.isEmpty {
                emptyStateView
            } else {
                videoListView
            }
            
            // Нижняя панель действий и прогресса
            bottomActionPanel
        }
    }
    
    // MARK: - Секция фильтра и диапазона
    
    private var filterSection: some View {
        VStack(spacing: 12) {
            // Заголовок секции с кнопкой повторного сканирования
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Диапазон длительности видео:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("от \(String(format: "%.1f", manager.minDuration)) с  до  \(String(format: "%.1f", manager.maxDuration)) с")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                Spacer()
                Button {
                    manager.scanForVideos()
                } label: {
                    Label("Сканировать", systemImage: "arrow.clockwise")
                        .font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isConverting)
            }
            
            // Быстрые пресеты для выбора
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    presetButton(title: "2.0 – 3.0 с (Обычно)", min: 2.0, max: 3.0)
                    presetButton(title: "1.5 – 3.0 с", min: 1.5, max: 3.0)
                    presetButton(title: "2.0 – 4.0 с", min: 2.0, max: 4.0)
                    presetButton(title: "1.0 – 5.0 с", min: 1.0, max: 5.0)
                    presetButton(title: "До 3.0 с", min: 0.5, max: 3.0)
                }
            }
            
            Divider()
            
            // Ручные регуляторы «ОТ» и «ДО»
            VStack(spacing: 8) {
                // ОТ:
                HStack {
                    Text("От:")
                        .font(.subheadline.bold())
                        .frame(width: 32, alignment: .leading)
                    
                    Slider(value: $manager.minDuration, in: 0.5...manager.maxDuration, step: 0.1)
                        .tint(.blue)
                        .onChange(of: manager.minDuration) { _ in
                            if manager.minDuration > manager.maxDuration {
                                manager.maxDuration = manager.minDuration
                            }
                        }
                    
                    Text("\(String(format: "%.1f", manager.minDuration)) с")
                        .font(.system(.subheadline, design: .monospaced))
                        .frame(width: 45, alignment: .trailing)
                    
                    Stepper("", value: $manager.minDuration, in: 0.5...manager.maxDuration, step: 0.1)
                        .labelsHidden()
                }
                
                // ДО:
                HStack {
                    Text("До:")
                        .font(.subheadline.bold())
                        .frame(width: 32, alignment: .leading)
                    
                    Slider(value: $manager.maxDuration, in: manager.minDuration...15.0, step: 0.1)
                        .tint(.blue)
                        .onChange(of: manager.maxDuration) { _ in
                            if manager.maxDuration < manager.minDuration {
                                manager.minDuration = manager.maxDuration
                            }
                        }
                    
                    Text("\(String(format: "%.1f", manager.maxDuration)) с")
                        .font(.system(.subheadline, design: .monospaced))
                        .frame(width: 45, alignment: .trailing)
                    
                    Stepper("", value: $manager.maxDuration, in: manager.minDuration...15.0, step: 0.1)
                        .labelsHidden()
                }
            }
            .disabled(manager.isConverting)
            
            Divider()
            
            Toggle("Удалять исходные видео после конвертации", isOn: $manager.deleteOriginalsAfterConversion)
                .font(.footnote)
                .tint(.red)
                .disabled(manager.isConverting)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    
    private func presetButton(title: String, min: Double, max: Double) -> some View {
        let isSelected = abs(manager.minDuration - min) < 0.05 && abs(manager.maxDuration - max) < 0.05
        return Button {
            manager.minDuration = min
            manager.maxDuration = max
            manager.scanForVideos()
        } label: {
            Text(title)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color(uiColor: .tertiarySystemFill))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .disabled(manager.isConverting)
    }
    
    // MARK: - Список видео
    
    private var videoListView: some View {
        List {
            Section {
                ForEach(manager.videos) { item in
                    HStack(spacing: 14) {
                        // Миниатюра
                        ZStack(alignment: .bottomTrailing) {
                            if let thumbnail = item.thumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(uiColor: .tertiarySystemFill))
                                    .frame(width: 64, height: 64)
                                    .overlay(
                                        Image(systemName: "video.fill")
                                            .foregroundColor(.secondary)
                                    )
                            }
                            
                            Text(item.formattedDuration)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.75))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(3)
                        }
                        
                        // Информация
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.creationDateFormatted)
                                .font(.subheadline.bold())
                            
                            statusLabel(for: item.status)
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Найдено роликов: \(manager.videos.count)")
            }
        }
        .listStyle(.insetGrouped)
    }
    
    @ViewBuilder
    private func statusLabel(for status: ConversionStatus) -> some View {
        switch status {
        case .pending:
            Text(status.displayText)
                .font(.caption)
                .foregroundColor(.secondary)
        case .converting:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.7)
                Text(status.displayText)
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        case .completed:
            Label(status.displayText, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .failed(let msg):
            Label("Ошибка: \(msg)", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(1)
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Видео не найдены")
                .font(.headline)
            Text("В галерее нет видео продолжительностью от \(String(format: "%.1f", manager.minDuration)) до \(String(format: "%.1f", manager.maxDuration)) секунд.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Повторить поиск") {
                manager.scanForVideos()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
    }
    
    // MARK: - Нижняя панель действий
    
    private var bottomActionPanel: some View {
        VStack(spacing: 12) {
            if manager.isConverting {
                VStack(spacing: 6) {
                    ProgressView(value: manager.currentProgress, total: 1.0)
                        .tint(.blue)
                    Text(manager.progressMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            } else {
                Button {
                    Task {
                        await manager.convertAllVideos()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "livephoto")
                        Text("Конвертировать все (\(manager.videos.count)) в Live Photo")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(manager.videos.isEmpty ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(manager.videos.isEmpty)
                .padding(.horizontal)
                
                if manager.deleteOriginalsAfterConversion {
                    Text("ℹ️ При удалении оригиналов система iOS покажет стандартный запрос подтверждения.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
        .padding(.vertical, 12)
        .background(Color(uiColor: .systemBackground).shadow(radius: 2))
    }
    
    // MARK: - Экран журнала логов
    
    private var logsSheetView: some View {
        NavigationStack {
            List(manager.statusLog, id: \.self) { line in
                Text(line)
                    .font(.system(.footnote, design: .monospaced))
            }
            .navigationTitle("Журнал операций")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") {
                        showLogsSheet = false
                    }
                }
            }
        }
    }
    
    // MARK: - Экран восстановления дат
    
    private var dateSyncSheetView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Баннер с объяснением
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title)
                                .foregroundColor(.blue)
                            Text("Восстановление исходных дат")
                                .font(.headline)
                        }
                        
                        Text("Если вы уже конвертировали видео и хотите вернуть на созданные Live Photo их точные оригинальные даты и время съемки:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    
                    // Шаги действий
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Инструкция:")
                            .font(.headline)
                        
                        HStack(alignment: .top, spacing: 12) {
                            Text("1")
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.blue)
                                .clipShape(Circle())
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Восстановите видео из корзины")
                                    .font(.subheadline.bold())
                                Text("Откройте приложение **«Фото» → Альбомы → «Недавно удаленные»**, нажмите **«Выбрать» → «Восстановить все»**.")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack(alignment: .top, spacing: 12) {
                            Text("2")
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.blue)
                                .clipShape(Circle())
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Запустите синхронизацию")
                                    .font(.subheadline.bold())
                                Text("Нажмите кнопку ниже: приложение сопоставит Live Photo с восстановленными роликами, перенесет точные даты съемки и геолокацию, а затем снова удалит оригиналы.")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    
                    // Кнопка синхронизации
                    Button {
                        Task {
                            await manager.syncLivePhotoDatesWithRestoredVideos()
                        }
                    } label: {
                        HStack {
                            if manager.isSyncingDates {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "calendar.badge.clock")
                            }
                            Text(manager.isSyncingDates ? "Синхронизация..." : "Синхронизировать даты с оригиналами")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(manager.isSyncingDates ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(manager.isSyncingDates)
                    
                    if !manager.syncStatusMessage.isEmpty {
                        Text(manager.syncStatusMessage)
                            .font(.subheadline.bold())
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Синхронизация дат")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        showDateSyncSheet = false
                    }
                }
            }
        }
    }
}
