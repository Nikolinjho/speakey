import Foundation
import FluidAudio

@main struct OfflineTests {
    static func main() async {
        let tests = DiagnosticTests()
        DownloadUtils.enforceOffline = true
        let url = URL(string: "https://invalid.invalid/model")!
        do {
            _ = try await DownloadUtils.fetchWithAuth(from: url)
            tests.check("Офлайн-запрос отклоняется", false)
        } catch {
            tests.check("Офлайн-запрос отклоняется до сети", (error as? URLError)?.code == .notConnectedToInternet)
        }
        do {
            _ = try await DownloadUtils.fetchHuggingFaceFile(from: url, description: "проверка", maxAttempts: 1)
            tests.check("Загрузка файла отклоняется", false)
        } catch {
            tests.check("Загрузка файла отклоняется до сети", (error as? URLError)?.code == .notConnectedToInternet)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = directory.appendingPathComponent(Repo.parakeetV3.folderName)
        try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let marker = cache.appendingPathComponent("сохранить.txt")
        try! Data("кэш".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await DownloadUtils.loadModels(.parakeetV3, modelNames: ["missing.mlmodelc"], directory: directory)
            tests.check("Отсутствующая модель отклоняется", false)
        } catch {
            tests.check("Ошибка загрузки не удаляет кэш", FileManager.default.fileExists(atPath: marker.path))
        }
        let download = directory.appendingPathComponent("не-создавать")
        do {
            try await DownloadUtils.downloadRepo(.parakeetV3, to: download)
            tests.check("Загрузка репозитория отклоняется", false)
        } catch {
            tests.check("Репозиторий не создаётся в офлайне",
                        (error as? URLError)?.code == .notConnectedToInternet
                        && !FileManager.default.fileExists(atPath: download.path))
        }
        do {
            try await DownloadUtils.downloadSubdirectory(.parakeetV3, subdirectory: "модель", to: download)
            tests.check("Загрузка подкаталога отклоняется", false)
        } catch {
            tests.check("Подкаталог не создаётся в офлайне",
                        (error as? URLError)?.code == .notConnectedToInternet
                        && !FileManager.default.fileExists(atPath: download.path))
        }
        DownloadUtils.enforceOffline = false
        tests.check("Явное скачивание можно разрешить", !DownloadUtils.enforceOffline)
        tests.finish()
    }
}
