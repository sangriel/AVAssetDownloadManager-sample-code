//
//  AVAssetDownloadManager.swift
//
//  Created by sangmin han on 2023/05/03.
//



import Foundation
import UIKit
import AVFoundation

final class AVAssetDownloadManager : NSObject {
    static let shared = AVAssetDownloadManager()
    typealias downloadCallBack = ((_ originUrl : String, _ cacheUrl : URL) -> ())
    
    enum CacheDirectoryType {
        case userManagedAssetDirectory
        case MyFoldereCacheDirectory
    }
    
    private var dirPathURL : URL? = {
        let nsDocumentDirectory = FileManager.SearchPathDirectory.cachesDirectory
        let nsUserDomainMask = FileManager.SearchPathDomainMask.userDomainMask
        let paths = NSSearchPathForDirectoriesInDomains(nsDocumentDirectory, nsUserDomainMask, true)
        if let dirpath = paths.first {
            return URL(fileURLWithPath: dirpath).appendingPathComponent("MyFolder/Caches")
        }
        else {
            return nil
        }
    }()
    private var activeDownloadSession : [String : AVAssetDownLoader] = [:]
    private var reservedCallback : [String : downloadCallBack] = [:]
    
    private override init() {
        super.init()
        guard let dirPathURL = dirPathURL else { return }
        do {
            try FileManager.default.createDirectory(at: dirPathURL, withIntermediateDirectories: true)
        }
        catch( let error) {
            debugLog("cache directory creation error \(error.localizedDescription)")
        }
    }
    
    func downLoadStream(sessionIdentifier : String, urlString : String, downLoadCallback : downloadCallBack? ) {
        if ShortFormConfigurationInfosManager.shared.shortsConfiguration.isCached == false {
            return
        }
        guard activeDownloadSession[sessionIdentifier] == nil else { return }
        guard getCachedData(with: urlString) == nil else { return }
        let downloadSession = AVAssetDownLoader(sessionIdentifier: sessionIdentifier, urlString: urlString, assetDownloadDelegate: self)
        activeDownloadSession[sessionIdentifier] = downloadSession
        reservedCallback[sessionIdentifier] = downLoadCallback
    }
    
    func cancelDownload(for sessionIdentifier : String){
        if let activeSession = activeDownloadSession[sessionIdentifier] {
            activeSession.cancelDownloading()
            activeDownloadSession.removeValue(forKey: sessionIdentifier)
        }
    }
    
    
    func getCachedData(with urlString : String) -> URL? {
        guard let dirPathURL = dirPathURL else { return  nil }
        guard let searchPath = self.getFileNameFromUrl(url: urlString) else { return nil }
        let searchURL = dirPathURL.appendingPathComponent("\(searchPath)")
        
        let fileManager = FileManager.default
        
        if fileManager.fileExists(atPath: searchURL.path) {
            return searchURL
        }
        else {
            return nil
        }
    }
    
    private func moveDownloadedData(from : URL, to : String) {
        guard let dirPathURL = dirPathURL else { return }
        guard let destinationPath = self.getFileNameFromUrl(url: to) else { return }
        let destinationUrl = dirPathURL.appendingPathComponent("\(destinationPath)")
        
        do {
            try FileManager.default.moveItem(at: from, to: destinationUrl)
        }
        catch(let error) {
            debugLog("cache move error \(error.localizedDescription)")
        }
    }

    
    private func getFileNameFromUrl(url : String) -> String? {
        guard let nsUrl = NSURL(string: url), let pathExtension = nsUrl.pathExtension else { return nil }
        guard let url = URLComponents(string: url) else { return nil }
    
        return "somethingIndentical"
    }
    
    
    //MARK: - delete functions
    func deleteCaches(type : CacheDirectoryType) {
        if type == .userManagedAssetDirectory {
            self.deleteUserManagedAssetLibraryDirectory()
        }
        else {
            self.deleteMyFoldereCacheDirectory()
        }
    }
    
    private func deleteUserManagedAssetLibraryDirectory() {
        DispatchQueue.global(qos: .background).async {
            if let userManagedAssetsURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
                do {
                    let fileURLs = try FileManager.default.contentsOfDirectory(at: userManagedAssetsURL, includingPropertiesForKeys: nil)
                    for fileURL in fileURLs {
                        if fileURL.absoluteString.contains("com.apple.UserManagedAssets") {
                            try FileManager.default.removeItem(at: fileURL)
                        }
                    }
                } catch(let error) {
                    debugLog("library cache delete error \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func deleteMyFoldereCacheDirectory() {
        DispatchQueue.global(qos: .background).async {
            guard let dirPath = self.dirPathURL else { return }
            do {
                let fileUrls = try FileManager.default.contentsOfDirectory(at: dirPath, includingPropertiesForKeys: nil)
                
                for fileUrl in fileUrls {
                    try FileManager.default.removeItem(at: fileUrl)
                }
            }
            catch(let error) {
                debugLog("cache delete error \(error.localizedDescription)")
            }
        }
    }
    
    //MARK: -CacheDirectorySize function
    //TODO: -gets smaller fileSize than actual size
    func getCacheDirectorySize() -> String? {
        guard let dirPathURL = dirPathURL else { return nil }
        do {
            let fileList = try FileManager.default.contentsOfDirectory(at: dirPathURL, includingPropertiesForKeys: nil)
            var fileSize : Int64 = 0
            for file in fileList {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    fileSize += attributes[FileAttributeKey.size] as? Int64 ?? 0
                }
                catch(let error){
                    continue
                }
            }
            let fileSizeStr = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            return fileSizeStr
        }
        catch(let error) {
            debugLog("cache size calculating error \(error.localizedDescription)")
            return nil
        }
    }
    
}
extension AVAssetDownloadManager : AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        if let identifier = session.configuration.identifier {
            moveDownloadedData(from: location, to: identifier)
            if activeDownloadSession[identifier] != nil {
                activeDownloadSession.removeValue(forKey: identifier)
            }
            else {
                // print("[AVAssetDownloadManager] activeSession for \(identifier) doesnt exist")
            }
            if let reservecallback = reservedCallback[identifier] {
                if let cachedUrl = getCachedData(with: identifier) {
                    reservecallback(identifier,cachedUrl)
                    reservedCallback.removeValue(forKey: identifier)
                }
            }
        }
        else {
            // print("[AVAssetDownloadManager] cant resolve identifier")
        }
    }
}

fileprivate class AVAssetDownLoader  {
    
    private var configuration : URLSessionConfiguration?
    private var downloadSession : AVAssetDownloadURLSession?
    private var urlString : String?
    private var asset : AVURLAsset?
    private var downLoadTask : AVAssetDownloadTask?
    
    init(sessionIdentifier : String, urlString: String, assetDownloadDelegate : AVAssetDownloadDelegate) {
        guard let url = URL(string: urlString) else { return }
        asset = AVURLAsset(url: url)
        
        
        configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        downloadSession = AVAssetDownloadURLSession(configuration: configuration!,
                                                    assetDownloadDelegate: assetDownloadDelegate,
                                                    delegateQueue: OperationQueue.main)
            
        downLoadTask = downloadSession!.makeAssetDownloadTask(asset: asset!,
                                                                  assetTitle: sessionIdentifier,
                                                                                       assetArtworkData: nil)!
        downLoadTask?.resume()
        
    }
    
    func cancelDownloading(){
        downLoadTask?.cancel()
        downLoadTask = nil
    }
}
