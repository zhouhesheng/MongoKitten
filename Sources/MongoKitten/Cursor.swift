//
//  Cursor.swift
//  MongoKitten
//
//  Created by Robbert Brandsma on 22-02-16.
//  Copyright © 2016 OpenKitten. All rights reserved.
//

import Foundation
import BSON

public final class Cursor<T> {
    public let namespace: String
    public let server: Server
    private let connection: Connection
    fileprivate var cursorID: Int64
    fileprivate let chunkSize: Int32
    
    // documents already received by the server
    fileprivate var data: [T]
    
    typealias Transformer = (Document) -> (T?)
    let transform: Transformer
    
    /// If firstDataSet is nil, reply.documents will be passed to transform as initial data
    internal convenience init?(namespace: String, server: Server, connection: Connection, reply: Message, chunkSize: Int32, transform: @escaping Transformer) {
        guard case .Reply(_, _, _, let cursorID, _, _, let documents) = reply else {
            return nil
        }
        
        self.init(namespace: namespace, server: server, connection: connection, cursorID: cursorID, initialData: documents.flatMap(transform), chunkSize: chunkSize, transform: transform)
    }
    
    internal convenience init(cursorDocument cursor: Document, server: Server, connection: Connection, chunkSize: Int32, transform: @escaping Transformer) throws {
        guard let cursorID = cursor["id"].int64Value, let namespace = cursor["ns"].stringValue, let firstBatch = cursor["firstBatch"].documentValue else {
            throw MongoError.cursorInitializationError(cursorDocument: cursor)
        }
        
        self.init(namespace: namespace, server: server, connection: connection, cursorID: cursorID, initialData: firstBatch.arrayValue.flatMap{$0.documentValue}.flatMap(transform), chunkSize: chunkSize, transform: transform)
    }
    
    internal init(namespace: String, server: Server, connection: Connection, cursorID: Int64, initialData: [T], chunkSize: Int32, transform: @escaping Transformer) {
        self.namespace = namespace
        self.server = server
        self.connection = connection
        self.cursorID = cursorID
        self.data = initialData
        self.chunkSize = chunkSize
        self.transform = transform
    }
    
    public init<B>(base: Cursor<B>, transform: @escaping (B) -> (T?)) {
        self.namespace = base.namespace
        self.server = base.server
        self.connection = base.connection
        self.cursorID = base.cursorID
        self.chunkSize = base.chunkSize
        self.transform = {
            if let bValue = base.transform($0) {
                return transform(bValue)
            } else {
                return nil
            }
        }
        self.data = base.data.flatMap(transform)
    }
    
    /// Gets more information and puts it in the buffer
    fileprivate func getMore() {
        do {
            let request = Message.GetMore(requestID: server.nextMessageID(), namespace: namespace, numberToReturn: chunkSize, cursor: cursorID)
            
            let requestId = try server.send(message: request, overConnection: connection)
            let reply = try server.await(response: requestId)
            
            guard case .Reply(_, _, _, let cursorID, _, _, let documents) = reply else {
                throw InternalMongoError.incorrectReply(reply: reply)
            }
            
            self.data += documents.flatMap(transform)
            self.cursorID = cursorID
        } catch {
            print("Error fetching extra data from the server in \(self) with error: \(error)")
        }
    }
    
    deinit {
        if cursorID != 0 {
            do {
                let killCursorsMessage = Message.KillCursors(requestID: server.nextMessageID(), cursorIDs: [self.cursorID])
                try server.send(message: killCursorsMessage, overConnection: connection)
            } catch {
                print("Error while cleaning up MongoDB cursor \(self): \(error)")
            }
        }
    }
}

extension Cursor : Sequence {
    /// Makes an iterator to loop over the data this cursor points to
    /// - returns: The iterator
    public func makeIterator() -> AnyIterator<T> {
        return AnyIterator {
            if self.data.isEmpty && self.cursorID != 0 {
                // Get more data!
                self.getMore()
            }
            
            return self.data.isEmpty ? nil : self.data.removeFirst()
        }
    }
}

extension Cursor : CustomStringConvertible {
    public var description: String {
        return "MongoKitten.Cursor<\(namespace)>"
    }
}
