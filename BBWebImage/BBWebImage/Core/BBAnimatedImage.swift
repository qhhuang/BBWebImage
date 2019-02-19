//
//  BBAnimatedImage.swift
//  BBWebImage
//
//  Created by Kaibo Lu on 2/6/19.
//  Copyright © 2019 Kaibo Lu. All rights reserved.
//

import UIKit

private struct BBAnimatedImageFrame {
    fileprivate var image: UIImage? {
        didSet {
            if let currentImage = image {
                size = currentImage.size
            }
        }
    }
    fileprivate var size: CGSize?
    fileprivate var duration: TimeInterval
    
    fileprivate var bytes: Int64? { return image?.bb_bytes }
}

public class BBAnimatedImage: UIImage {
    public var bb_editor: BBWebImageEditor? {
        get {
            lock.wait()
            let e = editor
            lock.signal()
            return e
        }
        set {
            if let e = newValue, e.needData { return }
            lock.wait()
            editor = newValue
            lock.signal()
        }
    }
    
    public var bb_frameCount: Int { return frameCount }
    
    public var bb_loopCount: Int { return loopCount }
    
    public var bb_maxCacheSize: Int64 {
        get {
            lock.wait()
            let m = maxCacheSize!
            lock.signal()
            return m
        }
        set {
            lock.wait()
            if newValue >= 0 {
                autoUpdateMaxCacheSize = false
                maxCacheSize = newValue
            } else {
                autoUpdateMaxCacheSize = true
                updateCacheSize()
            }
            lock.signal()
        }
    }
    
    public var bb_currentCacheSize: Int64 {
        lock.wait()
        let s = currentCacheSize!
        lock.signal()
        return s
    }
    
    public var bb_originalImageData: Data { return decoder.imageData! }
    
    private var editor: BBWebImageEditor?
    private var frameCount: Int!
    private var loopCount: Int!
    private var maxCacheSize: Int64!
    private var currentCacheSize: Int64!
    private var autoUpdateMaxCacheSize: Bool!
    private var cachedFrameCount: Int!
    private var frames: [BBAnimatedImageFrame]!
    private var decoder: BBAnimatedImageCoder!
    private var views: NSHashTable<BBAnimatedImageView>!
    private var lock: DispatchSemaphore!
    private var sentinel: Int32!
    private var preloadTask: (() -> Void)?
    
    deinit {
        cancelPreloadTask()
        NotificationCenter.default.removeObserver(self)
    }
    
    public convenience init?(bb_data data: Data, decoder aDecoder: BBAnimatedImageCoder? = nil) {
        var tempDecoder = aDecoder
        var canDecode = false
        if tempDecoder == nil {
            if let manager = BBWebImageManager.shared.imageCoder as? BBImageCoderManager {
                for coder in manager.coders {
                    if let animatedCoder = coder as? BBAnimatedImageCoder,
                        animatedCoder.canDecode(data) {
                        tempDecoder = animatedCoder
                        canDecode = true
                        break
                    }
                }
            }
        }
        guard let currentDecoder = tempDecoder else { return nil }
        if !canDecode && !currentDecoder.canDecode(data) { return nil }
        currentDecoder.imageData = data
        guard let firstFrame = currentDecoder.imageFrame(at: 0, decompress: true),
            let firstFrameSourceImage = firstFrame.cgImage,
            let currentFrameCount = currentDecoder.frameCount,
            currentFrameCount > 0 else { return nil }
        var imageFrames: [BBAnimatedImageFrame] = []
        for i in 0..<currentFrameCount {
            if let duration = currentDecoder.duration(at: i) {
                let image = (i == 0 ? firstFrame : nil)
                let size = currentDecoder.imageFrameSize(at: i)
                imageFrames.append(BBAnimatedImageFrame(image: image, size: size, duration: duration))
            } else {
                return nil
            }
        }
        self.init(cgImage: firstFrameSourceImage, scale: 1, orientation: firstFrame.imageOrientation)
        frameCount = currentFrameCount
        loopCount = currentDecoder.loopCount ?? 0
        maxCacheSize = .max
        currentCacheSize = Int64(imageFrames.first!.bytes!)
        autoUpdateMaxCacheSize = true
        cachedFrameCount = 1
        frames = imageFrames
        decoder = currentDecoder
        views = NSHashTable(options: .weakMemory)
        lock = DispatchSemaphore(value: 1)
        sentinel = 0
        NotificationCenter.default.addObserver(self, selector: #selector(didReceiveMemoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    public func bb_imageFrame(at index: Int, decodeIfNeeded: Bool) -> UIImage? {
        if index >= frameCount { return nil }
        lock.wait()
        let cacheImage = frames[index].image
        let editor = self.editor
        lock.signal()
        return imageFrame(at: index,
                          cachedImage: cacheImage,
                          editor: editor,
                          decodeIfNeeded: decodeIfNeeded)
    }
    
    private func imageFrame(at index: Int,
                            cachedImage: UIImage?,
                            editor bbEditor: BBWebImageEditor?,
                            decodeIfNeeded: Bool) -> UIImage? {
        if let currentImage = cachedImage {
            if let editor = bbEditor {
                if currentImage.bb_imageEditKey == editor.key {
                    return currentImage
                } else if decodeIfNeeded {
                    if currentImage.bb_imageEditKey == nil {
                        let editedImage = editor.edit(currentImage, nil)
                        editedImage?.bb_imageEditKey = editor.key
                        return editedImage
                    } else if let imageFrame = decoder.imageFrame(at: index, decompress: false) {
                        let editedImage = editor.edit(imageFrame, nil)
                        editedImage?.bb_imageEditKey = editor.key
                        return editedImage
                    }
                }
            } else if currentImage.bb_imageEditKey == nil {
                return currentImage
            } else if decodeIfNeeded {
                return decoder.imageFrame(at: index, decompress: true)
            }
        }
        if !decodeIfNeeded { return nil }
        if let editor = bbEditor {
            if let imageFrame = decoder.imageFrame(at: index, decompress: false) {
                let editedImage = editor.edit(imageFrame, nil)
                editedImage?.bb_imageEditKey = editor.key
                return editedImage
            }
        } else {
            return decoder.imageFrame(at: index, decompress: true)
        }
        return nil
    }
    
    public func bb_duration(at index: Int) -> TimeInterval? {
        if index >= frameCount { return nil }
        lock.wait()
        let duration = frames[index].duration
        lock.signal()
        return duration
    }
    
    public func bb_updateCacheSizeIfNeeded() {
        lock.wait()
        defer { lock.signal() }
        if !autoUpdateMaxCacheSize { return }
        updateCacheSize()
    }
    
    private func updateCacheSize() {
        let total = Int64(Double(UIDevice.totalMemory) * 0.2)
        let free = Int64(Double(UIDevice.freeMemory) * 0.6)
        maxCacheSize = min(total, free)
    }
    
    public func bb_preloadImageFrame(fromIndex startIndex: Int) {
        if startIndex >= frameCount { return }
        lock.wait()
        let shouldReturn = (preloadTask != nil || cachedFrameCount >= frameCount)
        lock.signal()
        if shouldReturn { return }
        let sentinel = self.sentinel
        let work: () -> Void = { [weak self] in
            guard let self = self, sentinel == self.sentinel else { return }
            self.lock.wait()
            let cleanCache = (self.currentCacheSize > self.maxCacheSize)
            self.lock.signal()
            if cleanCache {
                for i in 0..<self.frameCount {
                    let index = (startIndex + self.frameCount * 2 - i - 2) % self.frameCount // last second frame of start index
                    var shouldBreak = false
                    self.lock.wait()
                    if let oldImage = self.frames[index].image {
                        self.frames[index].image = nil
                        self.cachedFrameCount -= 1
                        self.currentCacheSize -= oldImage.bb_bytes
                        shouldBreak = (self.currentCacheSize <= self.maxCacheSize)
                    }
                    self.lock.signal()
                    if shouldBreak { break }
                }
                return
            }
            for i in 0..<self.frameCount {
                let index = (startIndex + i) % self.frameCount
                if let image = self.bb_imageFrame(at: index, decodeIfNeeded: true) {
                    if sentinel != self.sentinel { return }
                    var shouldBreak = false
                    self.lock.wait()
                    if let oldImage = self.frames[index].image {
                        if oldImage.bb_imageEditKey != image.bb_imageEditKey {
                            if self.currentCacheSize + image.bb_bytes - oldImage.bb_bytes <= self.maxCacheSize {
                                self.frames[index].image = image
                                self.cachedFrameCount += 1
                                self.currentCacheSize += image.bb_bytes - oldImage.bb_bytes
                            } else {
                                shouldBreak = true
                            }
                        }
                    } else if self.currentCacheSize + image.bb_bytes <= self.maxCacheSize {
                        self.frames[index].image = image
                        self.cachedFrameCount += 1
                        self.currentCacheSize += image.bb_bytes
                    } else {
                        shouldBreak = true
                    }
                    self.lock.signal()
                    if shouldBreak { break }
                }
            }
            self.lock.wait()
            if sentinel == self.sentinel { self.preloadTask = nil }
            self.lock.signal()
        }
        lock.wait()
        preloadTask = work
        BBDispatchQueuePool.default.async(work: work)
        lock.signal()
    }
    
    public func bb_preloadAllImageFrames() {
        lock.wait()
        autoUpdateMaxCacheSize = false
        maxCacheSize = .max
        cachedFrameCount = 0
        currentCacheSize = 0
        for i in 0..<frames.count {
            if let image = bb_imageFrame(at: i, decodeIfNeeded: true) {
                frames[i].image = image
                cachedFrameCount += 1
                currentCacheSize += image.bb_bytes
            }
        }
        lock.signal()
    }
    
    public func bb_didAddToView(_ view: BBAnimatedImageView) {
        views.add(view)
    }
    
    public func bb_didRemoveFromView(_ view: BBAnimatedImageView) {
        views.remove(view)
        if views.count <= 0 {
            cancelPreloadTask()
            clearAsynchronously(completion: nil)
        }
    }
    
    private func cancelPreloadTask() {
        lock.wait()
        if preloadTask != nil {
            OSAtomicIncrement32(&sentinel)
            preloadTask = nil
        }
        lock.signal()
    }
    
    private func clearAsynchronously(completion: (() -> Void)?) {
        BBDispatchQueuePool.default.async { [weak self] in
            guard let self = self else { return }
            self.clear()
            completion?()
        }
    }
    
    private func clear() {
        lock.wait()
        for i in 0..<frames.count {
            frames[i].image = nil
        }
        cachedFrameCount = 0
        currentCacheSize = 0
        lock.signal()
    }
    
    @objc private func didReceiveMemoryWarning() {
        clearAsynchronously { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self else { return }
                self.bb_updateCacheSizeIfNeeded()
            }
        }
    }
    
    @objc private func didEnterBackground() {
        clear()
    }
    
    @objc private func didBecomeActive() {
        bb_updateCacheSizeIfNeeded()
    }
}