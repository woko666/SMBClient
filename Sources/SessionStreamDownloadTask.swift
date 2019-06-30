//
//  SessionDownloadTask.swift
//  SMBClient
//
//  Created by Seth Faxon on 9/5/17.
//  Copyright © 2017 Filmic. All rights reserved.
//

import Foundation
#if os(iOS)
import UIKit
#endif

import libdsm

public protocol SessionStreamDownloadTaskDelegate: class {
    func downloadTaskDone()
    func downloadTask(totalBytesReceived: UInt64, totalBytesExpected: UInt64, data: Data)
    func downloadTask(didCompleteWithError: SessionDownloadTask.SessionDownloadError)
}

public class SessionStreamDownloadTask: SessionTask {
    var sourceFile: SMBFile
    var bytesReceived: UInt64?
    var bytesExpected: UInt64?
    var file: SMBFile?
    var seekOffset: UInt64 = 0
    //var data = Data()
    public weak var delegate: SessionStreamDownloadTaskDelegate?

    var hashForFilePath: String {
        let filepath = self.sourceFile.path.routablePath.lowercased()
        return "\(filepath.hashValue)"
    }

    public init(session: SMBSession,
                sourceFile: SMBFile,
                offset: UInt64 = 0,
                delegate: SessionStreamDownloadTaskDelegate? = nil) {
        self.sourceFile = sourceFile
        self.delegate = delegate
        self.seekOffset = offset
        super.init(session: session)
    }

    private func delegateError(_ error: SessionDownloadTask.SessionDownloadError) {
        self.delegateQueue.async {
            self.delegate?.downloadTask(didCompleteWithError: error)
        }
    }

    override func performTaskWith(operation: BlockOperation) {
        if operation.isCancelled {
            delegateError(.cancelled)
            return
        }

        var treeId = smb_tid(0)
        var fileId = smb_fd(0)

        // Connect to the volume/share
        let treeConnResult = self.session.treeConnect(volume: self.sourceFile.path.volume)
        switch treeConnResult {
        case .failure:
            delegateError(.serverNotFound)
        case .success(let t):
            treeId = t
        }

        if operation.isCancelled {
            self.cleanupBlock(treeId: treeId, fileId: fileId)
            return
        }

        self.file = self.request(file: sourceFile, inTree: treeId)

        guard let file = self.file else {
            delegateError(.fileNotFound)
            self.cleanupBlock(treeId: treeId, fileId: fileId)
            return
        }

        if operation.isCancelled {
            delegateError(.cancelled)
            self.cleanupBlock(treeId: treeId, fileId: fileId)
            return
        }

        self.bytesExpected = file.fileSize > seekOffset ? file.fileSize - seekOffset : 0

        // ### Open file handle
        let fopen = self.session.fileOpen(treeId: treeId, path: file.downloadPath, mod: UInt32(SMB_MOD_READ))
        switch fopen {
        case .failure:
            delegateError(.fileNotFound)
            self.cleanupBlock(treeId: treeId, fileId: 0)
            return
        case .success(let f):
            fileId = f
        }

        if operation.isCancelled {
            self.cleanupBlock(treeId: treeId, fileId: fileId)
            return
        }

        self.bytesReceived = 0

        #if os(iOS)
        self.backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(expirationHandler: {
            self.suspend()
        })
        #endif

        if seekOffset > 0 {
            let fSeek = self.session.fileSeek(fileId: fileId, offset: seekOffset)
            switch fSeek {
            case .failure:
                delegateError(.downloadFailed)
                self.cleanupBlock(treeId: treeId, fileId: fileId)
                return
            case .success(let readBytes):
                self.bytesReceived = UInt64(readBytes)
            }
        }

        // ### Download bytes
        var bytesRead: Int = 0
        let bufferSize: Int = 65535

        var didAlreadyError = false

        repeat {
            var readData: Data?
            let readResult = self.session.fileRead(fileId: fileId, bufferSize: UInt(bufferSize))
            switch readResult {
            case .failure(let err):
                self.fail()

                switch err {
                case .unableToConnect:
                    delegateError(.lostConnection)
                default:
                    delegateError(.downloadFailed)
                }
                didAlreadyError = true
                break
            case .success(let data):
                bytesRead = data.count
                readData = data
            }

            if operation.isCancelled {
                break
            }

            self.bytesReceived = self.bytesReceived! + UInt64(bytesRead)
            //self.delegateQueue.async {
            if let readData = readData {
                //self.data.append(readData)
                self.delegate?.downloadTask(totalBytesReceived: self.bytesReceived!,
                                            totalBytesExpected: self.bytesExpected!,
                                            data: readData)
            }
            //}
        } while (bytesRead > 0)

        if operation.isCancelled || self.state != .running {
            self.cleanupBlock(treeId: treeId, fileId: fileId)
            if !didAlreadyError {
                delegateError(.cancelled)
            }
            return
        }

        self.state = .completed
        self.delegateQueue.async {
            self.delegate?.downloadTaskDone()
        }
        self.cleanupBlock(treeId: treeId, fileId: fileId)
    }

    override var canBeResumed: Bool {
        return false
    }

    func suspend() {
        if self.state != .running {
            return
        }
        self.taskOperation?.cancel()
        self.state = .cancelled
        self.taskOperation = nil
    }

    override public func cancel() {
        if self.state != .running {
            return
        }

        self.taskOperation?.cancel()
        self.state = .cancelled

        self.taskOperation = nil
    }
}
