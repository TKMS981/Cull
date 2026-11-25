// Usage: swiftc -o /tmp/mklive Scripts/make_live_photo.swift && /tmp/mklive still.jpg clip.mp4 out.JPG out.MOV
// Pairs a still and a clip into a Live Photo (shared content identifier) for simctl addmedia.

import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let srcImage = URL(fileURLWithPath: args[1]), srcVideo = URL(fileURLWithPath: args[2])
let outImage = URL(fileURLWithPath: args[3]), outVideo = URL(fileURLWithPath: args[4])
let id = UUID().uuidString

// Still: Apple MakerNote key 17 = content identifier
let s = CGImageSourceCreateWithURL(srcImage as CFURL, nil)!
let d = CGImageDestinationCreateWithURL(outImage as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
var props = (CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]) ?? [:]
props[kCGImagePropertyMakerAppleDictionary] = ["17": id]
CGImageDestinationAddImageFromSource(d, s, 0, props as CFDictionary)
precondition(CGImageDestinationFinalize(d))

// Video: content identifier + still-image-time timed metadata
try? FileManager.default.removeItem(at: outVideo)
let asset = AVURLAsset(url: srcVideo)
let sem = DispatchSemaphore(value: 0)
Task {
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let reader = try AVAssetReader(asset: asset)
    let readerOut = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(readerOut)
    let size = try await track.load(.naturalSize)
    let writer = try AVAssetWriter(outputURL: outVideo, fileType: .mov)
    let item = AVMutableMetadataItem()
    item.keySpace = .quickTimeMetadata
    item.key = "com.apple.quicktime.content.identifier" as NSString
    item.value = id as NSString
    item.dataType = "com.apple.metadata.datatype.UTF-8"
    writer.metadata = [item]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    let spec: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
                               kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8"]
    var desc: CMFormatDescription?
    CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &desc)
    let metaInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
    let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metaInput)
    writer.add(metaInput)
    writer.startWriting(); reader.startReading()
    writer.startSession(atSourceTime: .zero)
    let still = AVMutableMetadataItem()
    still.key = "com.apple.quicktime.still-image-time" as NSString
    still.keySpace = AVMetadataKeySpace(rawValue: "mdta")
    still.value = 0 as NSNumber
    still.dataType = "com.apple.metadata.datatype.int8"
    adaptor.append(AVTimedMetadataGroup(items: [still], timeRange: CMTimeRange(start: CMTime(value: 0, timescale: 1000), duration: CMTime(value: 200, timescale: 3000))))
    metaInput.markAsFinished()
    while let buf = readerOut.copyNextSampleBuffer() {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        input.append(buf)
    }
    input.markAsFinished()
    await writer.finishWriting()
    print("writer status", writer.status.rawValue, writer.error as Any)
    sem.signal()
}
sem.wait()
