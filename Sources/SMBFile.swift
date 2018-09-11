//
//  SMBFile.swift
//  SMBClient
//
//  Created by Seth Faxon on 9/1/17.
//  Copyright © 2017 Filmic. All rights reserved.
//

import libdsm

public struct SMBFile {
    public private(set) var path: SMBPath

    public var name: String

    public private(set) var fileSize: UInt64
    public private(set) var allocationSize: UInt64

    public private(set) var createdAt: Date?
    public private(set) var accessedAt: Date?
    public private(set) var writeAt: Date?
    public private(set) var modifiedAt: Date?

    public init?(fromURL url: URL) {
        guard let host = url.host else {
            return nil
        }
        guard let server = SMBServer(hostname: host) else {
            return nil
        }
        // url.pathComponents gives us a leading slash,
        // from above example this is:
        // ["/", "volume", "somePath"]
        var pathComponents = url.pathComponents
        // can't have a valid connection without a host and a volume
        guard pathComponents.count >= 2 else {
            return nil
        }

        // pop off the leading '/' that pathComponents gives us
        var popedComponent = "/"
        while popedComponent == "/" && pathComponents.count > 0 {
            popedComponent = pathComponents.removeFirst()
        }
        let volumeName = popedComponent
        let volume = SMBVolume(server: server, name: volumeName)

        // build directories from whatever is left
        var pathDirectories = [SMBDirectory]()
        while pathComponents.count > 0 {
            var pathName = pathComponents.removeFirst()
            if let p = pathName.removingPercentEncoding {
                pathName = p
            }
            let dir = SMBDirectory(name: pathName)
            pathDirectories.append(dir)
        }
        var directories = pathDirectories
        if let last = directories.last {
            self.name = last.name
            directories.removeLast()
        } else {
            return nil
        }
        self.path = SMBPath(volume: volume, directories: directories)
        self.fileSize = 0
        self.allocationSize = 0
    }

    init?(stat: OpaquePointer, parentPath: SMBPath) {
        self.path = parentPath
        guard let cName = smb_stat_name(stat) else { return nil }
        let pathAndFile = String(cString: cName).split(separator: "\\")
        guard let n = pathAndFile.last else { return nil }
        self.name = n.precomposedStringWithCanonicalMapping

        self.fileSize = smb_stat_get(stat, SMB_STAT_SIZE)
        self.allocationSize = smb_stat_get(stat, SMB_STAT_ALLOC_SIZE)

        /*self.createdAt = SMBFile.dateFrom(timestamp: smb_stat_get(stat, SMB_STAT_CTIME))
        self.modifiedAt = SMBFile.dateFrom(timestamp: smb_stat_get(stat, SMB_STAT_MTIME))
        self.accessedAt = SMBFile.dateFrom(timestamp: smb_stat_get(stat, SMB_STAT_ATIME))
        self.writeAt = SMBFile.dateFrom(timestamp: smb_stat_get(stat, SMB_STAT_WTIME))*/
    }

    init?(path: SMBPath, name: String) {
        self.path = path
        self.name = SMBFile.getUnicodeNFC(name)
        self.fileSize = 0
        self.allocationSize = 0
    }
    
    static func getUnicodeNFC(_ text:String) -> String {
        return (text as NSString).precomposedStringWithCanonicalMapping
    }
    static func getUnicodeNFD(_ text:String) -> String {
        return (text as NSString).decomposedStringWithCanonicalMapping
    }

    public var isHidden: Bool {
        return self.name.first == "."
    }

    internal var uploadPath: String {
        let slash = "\\"
        let dirs: [String] = self.path.directories.map { $0.name }
        let result = slash + dirs.joined(separator: slash) + slash + self.name
        return result
    }

    internal var downloadPath: String {
        let slash = "\\"
        return slash + self.uploadPath
    }

    fileprivate static func dateFrom(timestamp: UInt64) -> Date? {
        var base = DateComponents()
        base.day = 1
        base.month = 1
        base.year = 1601
        base.era = 1

        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(from: base)

        let newTimestamp: TimeInterval = TimeInterval(timestamp) / 10000000
        let result = baseDate?.addingTimeInterval(newTimestamp)

        return result
    }
}
