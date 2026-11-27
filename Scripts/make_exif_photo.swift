// Usage: swift Scripts/make_exif_photo.swift in.png out.jpg <index> [seconds-ago]  (adds sample camera EXIF + GPS)
// Taken 20 × index days ago unless seconds-ago is given.

import Foundation
import ImageIO
import UniformTypeIdentifiers
let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[2])
let idx = Int(args[3])!
let s = CGImageSourceCreateWithURL(src as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(s, 0, nil)!
let d = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
let secondsAgo = args.count > 4 ? Double(args[4])! : Double(86400 * 20 * idx)
let date = f.string(from: Date(timeIntervalSinceNow: -secondsAgo))
let props: [CFString: Any] = [
  kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
  kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "iPhone 17 Pro back triple camera 6.86mm f/1.78",
    kCGImagePropertyExifFNumber: 1.78, kCGImagePropertyExifExposureTime: 1.0/120, kCGImagePropertyExifISOSpeedRatings: [64 * idx],
    kCGImagePropertyExifFocalLenIn35mmFilm: 24, kCGImagePropertyExifDateTimeOriginal: date],
  kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.6586, kCGImagePropertyGPSLatitudeRef: "N",
    kCGImagePropertyGPSLongitude: 139.7454, kCGImagePropertyGPSLongitudeRef: "E"],
]
CGImageDestinationAddImage(d, img, props as CFDictionary)
precondition(CGImageDestinationFinalize(d))
