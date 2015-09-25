//
//  WMFImageController.swift
//  Wikipedia
//
//  Created by Brian Gerstle on 6/22/15.
//  Copyright (c) 2015 Wikimedia Foundation. All rights reserved.
//

import Foundation
import PromiseKit

///
/// @name Constants
///

public let WMFImageControllerErrorDomain = "WMFImageControllerErrorDomain"
public enum WMFImageControllerErrorCode: Int, CancellableErrorType {
    case DataNotFound
    case FetchCancelled
    case InvalidOrEmptyURL
    case Deinit

    var error: NSError {
        return NSError(domain: WMFImageControllerErrorDomain, code: self.rawValue, userInfo: nil)
    }

    public var cancelled: Bool {
        switch self {
            case .FetchCancelled, .InvalidOrEmptyURL, .Deinit:
                return true
            default:
                return false
        }
    }
}

public func ==(err: NSError, cacheErrCode: WMFImageControllerErrorCode) -> Bool {
    return err.code == cacheErrCode.rawValue
}

// need to declare the "flipped" version of NSError == WMFImageCacheErrorCode
public func ==(cacheErrorCode: WMFImageControllerErrorCode, err: NSError) -> Bool {
    return err == cacheErrorCode
}

@objc
public class WMFImageController : NSObject {
    public override class func initialize() {
        if self === WMFImageController.self {
            NSError.registerCancelledErrorDomain(WMFImageControllerErrorDomain,
                                                 code: WMFImageControllerErrorCode.FetchCancelled.rawValue)
        }
    }

    // MARK: - Initialization

    private static let defaultNamespace = "default"

    private static let _sharedInstance: WMFImageController = {
        let downloader = SDWebImageDownloader.sharedDownloader()
        let cache = SDImageCache.wmf_appSupportCacheWithNamespace(defaultNamespace)
        return WMFImageController(manager: SDWebImageManager(downloader: downloader, cache: cache),
                                  namespace: defaultNamespace)
    }()

    public static let backgroundImageFetchOptions: SDWebImageOptions = [.LowPriority, .ContinueInBackground]

    public class func sharedInstance() -> WMFImageController {
        return _sharedInstance
    }

    let imageManager: SDWebImageManager

    private let cancellingQueue: dispatch_queue_t

    private lazy var cancellables: NSMapTable = {
        NSMapTable.strongToWeakObjectsMapTable()
    }()

    public required init(manager: SDWebImageManager, namespace: String) {
        self.imageManager = manager;
        self.imageManager.cacheKeyFilter = { (url: NSURL?) in url?.wmf_schemelessURLString() }
        self.cancellingQueue = dispatch_queue_create("org.wikimedia.wikipedia.wmfimagecontroller.\(namespace)",
                                                     DISPATCH_QUEUE_SERIAL)
        super.init()
    }

    deinit {
        cancelAllFetches()
    }

    // MARK: - Complex Fetching

    /**
     Perform a cascading fetch which attempts to retrieve a "main" image from memory, or fall back to a
     placeholder while fetching the image in the background.
     
     The "cascade" executes the following:
     
     - if mainURL is in cache, return immediately
     - else, fetch placeholder from cache
     - then, mainURL from network
     
     - returns: A promise which is resolved when the entire cascade is finished, or rejected when an error occurs.
     */
    public func cascadingFetchWithMainURL(mainURL: NSURL?,
                                          cachedPlaceholderURL: NSURL?,
                                          mainImageBlock: (WMFImageDownload) -> Void,
                                          cachedPlaceholderImageBlock: (WMFImageDownload) -> Void) -> Promise<Void> {
        if hasImageWithURL(mainURL) {
            // if mainURL is cached, return it immediately w/o fetching placeholder
            return cachedImageWithURL(mainURL).then(mainImageBlock)
        }
        // return cached placeholder (if available)
        return cachedImageWithURL(cachedPlaceholderURL)
        // handle cached placeholder
        .then(cachedPlaceholderImageBlock)
        // ignore cache misses for placeholder
        .recover() { _ -> Promise<Void> in Promise() }
        // when placeholder handling is finished, fetch mainURL
        .then() { [weak self] in
            self?.fetchImageWithURL(mainURL) ?? WMFImageController.cancelledPromise()
        }
        // handle the main image
        .then(mainImageBlock)
    }


    /**
    Fetch the image at `url` slowly in the background.

    - parameter url: A URL pointing to an image.

    - returns: A promise which resolves when the image has been downloaded.
    */
    public func fetchImageWithURLInBackground(url: NSURL?) -> Promise<WMFImageDownload> {
        return fetchImageWithURL(url, options: WMFImageController.backgroundImageFetchOptions) as Promise<WMFImageDownload>
    }

    // MARK: - Simple Fetching

    /**
     Retrieve the data and uncompressed image for `url`.
     
     - parameter url: URL which corresponds to the image being retrieved. Ignores URL schemes.
     
     - returns: A `WMFImageDownload` with the image data and the origin it was loaded from.
     */
    public func fetchImageWithURL(
                    url: NSURL?,
                    options: SDWebImageOptions = SDWebImageOptions()) -> Promise<WMFImageDownload> {
        // HAX: make sure all image requests have a scheme (MW api sometimes omits one)
        return checkForValidURL(url) { url in
            let (cancellable, promise) =
            imageManager.promisedImageWithURL(url.wmf_urlByPrependingSchemeIfSchemeless(), options: options)
            addCancellableForURL(cancellable, url: url)
            return applyDebugTransformIfEnabled(promise)
        }
    }

    /// - returns: Whether or not a fetch is outstanding for an image with `url`.
    public func isDownloadingImageWithURL(url: NSURL) -> Bool {
        return imageManager.imageDownloader.isDownloadingImageAtURL(url)
    }

    // MARK: - Caching

    /// - returns: Whether or not the image corresponding to `url` has been downloaded (ignores URL schemes).
    public func hasImageWithURL(url: NSURL?) -> Bool {
        return url == nil ? false : imageManager.cachedImageExistsForURL(url!)
    }

    public func cachedImageInMemoryWithURL(url: NSURL?) -> UIImage? {
        return url == nil ? nil : imageManager.imageCache.imageFromMemoryCacheForKey(cacheKeyForURL(url!))
    }

    public func hasDataInMemoryForImageWithURL(url: NSURL?) -> Bool {
        return cachedImageInMemoryWithURL(url) != nil
    }

    public func hasDataOnDiskForImageWithURL(url: NSURL?) -> Bool {
        return url == nil ? false : imageManager.diskImageExistsForURL(url)
    }

    func diskDataForImageWithURL(url: NSURL?) -> NSData? {
        if let url = url {
            let path = imageManager.imageCache.defaultCachePathForKey(cacheKeyForURL(url))
            return NSFileManager.defaultManager().contentsAtPath(path)
        } else {
            return nil
        }
    }

    public func cachedImageWithURL(url: NSURL?) -> Promise<WMFImageDownload> {
        return checkForValidURL(url, then: cachedImageWithURL)
    }

    public func cachedImageWithURL(url: NSURL) -> Promise<WMFImageDownload> {
        let (cancellable, promise) = imageManager.imageCache.queryDiskCacheForKey(cacheKeyForURL(url))
        if let cancellable = cancellable {
            addCancellableForURL(cancellable, url: url)
        }
        return applyDebugTransformIfEnabled(promise.then() { image, origin in
            return WMFImageDownload(url: url, image: image, origin: origin.rawValue)
        })
    }

    // MARK: - Deletion

    public func clearMemoryCache() {
        imageManager.imageCache.clearMemory()
    }

    public func deleteImagesWithURLs(urls: [NSURL]) {
        self.imageManager.wmf_removeImageURLs(urls, fromDisk: true)
    }

    public func deleteImageWithURL(url: NSURL?) {
        self.imageManager.wmf_removeImageForURL(url, fromDisk: true)
    }

    public func deleteAllImages() {
        self.imageManager.imageCache.clearMemory()
        self.imageManager.imageCache.clearDisk()
    }

    /**
    Import image data associated with a URL from a file into the receiver's disk storage.

    - parameter filepath: Path the image data on disk.
    - parameter url:      The URL from which the data was downloaded.

    - returns: A promise which resolves after the migration was completed.
    */
    public func importImage(fromFile filepath: String, withURL url: NSURL) -> Promise<Void> {
        guard NSFileManager.defaultManager().fileExistsAtPath(filepath) else {
            NSLog("Source file does not exist: \(filepath)")
            // Do not treat this as an error, as the image record could have been created w/o data ever being imported.
            return Promise<Void>()
        }

        return dispatch_promise(on: dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0)) { [weak self] in
            guard let strongSelf: WMFImageController = self else {
                throw WMFImageControllerErrorCode.Deinit
            }

            if strongSelf.hasDataOnDiskForImageWithURL(url) {
                NSLog("Skipping import of image with URL \(url) since it's already in the cache, deleting it instead")
                try NSFileManager.defaultManager().removeItemAtPath(filepath)
                return
            }

            let diskCachePath = strongSelf.imageManager.imageCache.defaultCachePathForKey(strongSelf.cacheKeyForURL(url))
            let diskCacheURL = NSURL(fileURLWithPath: diskCachePath, isDirectory: false)
            let fileURL = NSURL(fileURLWithPath: filepath, isDirectory: false)

            do {
                try NSFileManager.defaultManager()
                                 .createDirectoryAtURL(diskCacheURL.URLByDeletingLastPathComponent!,
                                                       withIntermediateDirectories: true,
                                                       attributes: nil)
            } catch let fileExistsError as NSError where fileExistsError.code == NSFileWriteFileExistsError {
                NSLog("Ignoring file exists error for path \(fileExistsError)")
            }

            do {
                try NSFileManager.defaultManager().moveItemAtURL(fileURL, toURL: diskCacheURL)
            } catch let fileExistsError as NSError where fileExistsError.code == NSFileWriteFileExistsError {
                NSLog("Ignoring file exists error for path \(fileExistsError)")
            }
        }
    }

    private func cacheKeyForURL(url: NSURL) -> String {
        return imageManager.cacheKeyForURL(url)
    }

    /**
    Utility which returns a rejected promise for `nil` URLs, or passes valid URLs to function `then`.

    - parameter url:  An optional URL.
    - parameter then: The function to call if the URL is valid.

    - returns: A rejected promise with `InvalidOrEmptyURL` error if `url` is `nil`, otherwise the promise from `then`.
    */
    private func checkForValidURL(url: NSURL?, @noescape then: (NSURL) -> Promise<WMFImageDownload>) -> Promise<WMFImageDownload> {
        if url == nil { return Promise(error: WMFImageControllerErrorCode.InvalidOrEmptyURL.error) }
        else { return then(url!) }
    }

    // MARK: - Cancellation

    /// Cancel a pending fetch for an image at `url`.
    public func cancelFetchForURL(url: NSURL?) {
        if let url = url {
            weak var wself = self;
            dispatch_async(self.cancellingQueue) {
                let sself = wself
                if let cancellable = sself?.cancellables.objectForKey(url.absoluteString) as? Cancellable {
                    sself?.cancellables.removeObjectForKey(url.absoluteString)
                    cancellable.cancel()
                }
            }
        }
    }

    public func cancelAllFetches() {
        weak var wself = self;
        dispatch_async(self.cancellingQueue) {
            let sself = wself
            let currentCancellables = sself?.cancellables.objectEnumerator()!.allObjects as! [Cancellable]
            sself?.cancellables.removeAllObjects()
            dispatch_async(dispatch_get_global_queue(0, 0)) {
                for cancellable in currentCancellables {
                    cancellable.cancel()
                }
            }
        }
    }

    private func addCancellableForURL(cancellable: Cancellable, url: NSURL) {
        weak var wself = self;
        dispatch_async(self.cancellingQueue) {
            let sself = wself
            sself?.cancellables.setObject(cancellable, forKey: url.absoluteString)
        }
    }

    /// Utility for creating a `Promise` cancelled with a WMFImageController error
    class func cancelledPromise<T>() -> Promise<T> {
        return Promise(error: WMFImageControllerErrorCode.FetchCancelled.error)
    }

    /// Utility for creating an `AnyPromise` cancelled with a WMFImageController error
    class func cancelledPromise() -> AnyPromise {
        return AnyPromise(bound: cancelledPromise() as Promise<Void>)
    }
}

// MARK: - Objective-C Bridge

extension WMFImageController {
    /**
     Objective-C-compatible variant of fetchImageWithURL(url:options:) using default options & returning an `AnyPromise`.
     
     - returns: `AnyPromise` which resolves to `WMFImageDownload`.
     */
    @objc public func fetchImageWithURL(url: NSURL?) -> AnyPromise {
        return AnyPromise(bound: fetchImageWithURL(url))
    }

    /**
    Objective-C-compatible variant of fetchImageWithURL(url:options:) returning an `AnyPromise`.

    - returns: `AnyPromise` which resolves to `WMFImageDownload`.
    */
    @objc public func fetchImageWithURL(url: NSURL?, options: SDWebImageOptions) -> AnyPromise {
        return AnyPromise(bound: fetchImageWithURL(url, options: options))
    }

    /**
    Objective-C-compatible variant of fetchImageWithURLInBackground(url:) returning an `AnyPromise`.

    - returns: `AnyPromise` which resolves to `WMFImageDownload`.
    */
    @objc public func fetchImageWithURLInBackground(url: NSURL?) -> AnyPromise {
        return AnyPromise(bound: fetchImageWithURLInBackground(url))
    }

    /**
     Objective-C-compatible variant of cachedImageWithURL(url:) returning an `AnyPromise`.
     
     - returns: `AnyPromise` which resolves to `UIImage?`, where the image is present on a cache hit, and `nil` on a miss.
     */
    @objc public func cachedImageWithURL(url: NSURL?) -> AnyPromise {
        return AnyPromise(bound:
            cachedImageWithURL(url)
            .then() { $0.image }
            .recover() { (err) -> Promise<UIImage?> in
                let error = err as NSError
                if error.domain == WMFImageControllerErrorDomain
                    && error.code == WMFImageControllerErrorCode.DataNotFound.rawValue {
                        return Promise<UIImage?>(nil)
                } else {
                    return Promise(error: err)
                }
            })
    }

    @objc public func cascadingFetchWithMainURL(mainURL: NSURL?,
                                          cachedPlaceholderURL: NSURL?,
                                          mainImageBlock: (WMFImageDownload) -> Void,
                                          cachedPlaceholderImageBlock: (WMFImageDownload) -> Void) -> AnyPromise {
        let promise: Promise<Void> =
        cascadingFetchWithMainURL(mainURL,
                                  cachedPlaceholderURL: cachedPlaceholderURL,
                                  mainImageBlock: mainImageBlock,
                                  cachedPlaceholderImageBlock: cachedPlaceholderImageBlock)
        return AnyPromise(bound: promise)
    }
}
