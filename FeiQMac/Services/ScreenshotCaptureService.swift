//
//  ScreenshotCaptureService.swift
//  FeiQMac
//
//  使用 macOS 原生 screencapture 交互选区，并返回 PNG 数据供聊天输入区使用。
//

import Foundation

protocol ScreenshotCaptureService: AnyObject {
    func captureInteractive(
        completion: @escaping (Result<Data, Error>) -> Void
    )
}

enum ScreenshotCaptureError: LocalizedError {
    case unavailable
    case cancelled
    case failed(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "当前 macOS 不支持截屏功能"
        case .cancelled:
            return "已取消截屏"
        case .failed(let message):
            return "截屏失败：\(message)"
        case .emptyResult:
            return "没有截取到有效图片"
        }
    }
}

final class MacScreenshotCaptureService: ScreenshotCaptureService {
    private let fileManager: FileManager
    private let executableURL: URL

    init(
        fileManager: FileManager = .default,
        executableURL: URL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    ) {
        self.fileManager = fileManager
        self.executableURL = executableURL
    }

    func captureInteractive(
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            completion(.failure(ScreenshotCaptureError.unavailable))
            return
        }

        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("feiq-screenshot-\(UUID().uuidString)")
            .appendingPathExtension("png")
        let process = Process()
        process.executableURL = executableURL
        // -i: interactive area/window selection
        // -o: omit window shadow when a window is selected
        // -t png: return a lossless image for the attachment pipeline
        process.arguments = ["-i", "-o", "-t", "png", outputURL.path]
        process.terminationHandler = { [fileManager] process in
            defer {
                try? fileManager.removeItem(at: outputURL)
            }

            guard process.terminationStatus == 0 else {
                completion(.failure(ScreenshotCaptureError.cancelled))
                return
            }

            do {
                let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
                guard !data.isEmpty else {
                    completion(.failure(ScreenshotCaptureError.emptyResult))
                    return
                }
                completion(.success(data))
            } catch {
                completion(.failure(ScreenshotCaptureError.failed(error.localizedDescription)))
            }
        }

        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: outputURL)
            completion(.failure(ScreenshotCaptureError.failed(error.localizedDescription)))
        }
    }
}
