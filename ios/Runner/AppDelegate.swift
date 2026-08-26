import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let mediaChannelName = "duck_downloader/media"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: mediaChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self else { return }
        switch call.method {
        case "saveVideo":
          self.savePhotoLibraryAsset(call: call, result: result, isVideo: true)
        case "saveImage":
          self.savePhotoLibraryAsset(call: call, result: result, isVideo: false)
        case "saveAudioToMusic":
          result(FlutterError(
            code: "unavailable",
            message: "Use Save to Files for audio on iOS.",
            details: nil
          ))
        case "setVideoPlaying":
          // iOS handles audio/video session automatically — no native action needed.
          result(nil)
        case "enterPiP":
          // iOS Picture-in-Picture requires AVPlayerViewController which is not
          // set up in this app. Return a graceful error so Flutter can show a
          // friendly message instead of crashing with MissingPluginException.
          result(FlutterError(
            code: "pip_not_supported",
            message: "Picture-in-Picture is not supported on this device.",
            details: nil
          ))
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Saves a downloaded video or image into the user's Photos library.
  /// Uses the `.addOnly` authorization level so iOS only asks for write access.
  private func savePhotoLibraryAsset(
    call: FlutterMethodCall,
    result: @escaping FlutterResult,
    isVideo: Bool
  ) {
    guard
      let args = call.arguments as? [String: Any],
      let path = args["path"] as? String
    else {
      result(FlutterError(code: "invalid_args", message: "Missing file path.", details: nil))
      return
    }

    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      result(FlutterError(code: "missing_file", message: "Downloaded file is not available.", details: nil))
      return
    }

    let completeSave: () -> Void = {
      PHPhotoLibrary.shared().performChanges({
        if isVideo {
          PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } else {
          PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
      }) { success, error in
        DispatchQueue.main.async {
          if success {
            result(["success": true, "uri": url.absoluteString])
          } else {
            result(FlutterError(
              code: "save_failed",
              message: error?.localizedDescription ?? "Could not save this file to Photos.",
              details: nil
            ))
          }
        }
      }
    }

    if #available(iOS 14, *) {
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        if status == .authorized || status == .limited {
          completeSave()
        } else {
          DispatchQueue.main.async {
            result(FlutterError(code: "permission_denied", message: "Photos permission was denied.", details: nil))
          }
        }
      }
    } else {
      PHPhotoLibrary.requestAuthorization { status in
        if status == .authorized {
          completeSave()
        } else {
          DispatchQueue.main.async {
            result(FlutterError(code: "permission_denied", message: "Photos permission was denied.", details: nil))
          }
        }
      }
    }
  }
}
